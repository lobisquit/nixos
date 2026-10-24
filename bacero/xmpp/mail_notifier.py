#!/usr/bin/env python3
"""Watch IMAP folders and forward every new mail to an XMPP account.

Configuration: the YAML file $CREDENTIALS_DIRECTORY/configuration
(provided by systemd), like this

    watchers:
      - imap_host: imap.example.com
        imap_port: 993                 # optional, default 993 (TLS)
        imap_user: me@example.com
        imap_password: secret
        folder: INBOX/Vinted
        xmpp_jid: vinted@lovisotto.it  # bot account that sends
        xmpp_password: secret
        recipient: enrico@lovisotto.it # who receives the notifications
        subject_blacklist:             # optional; regexes, case-insensitive
          - tra i preferiti
          - ^Nuovi articoli
        max_chars: 2000                # optional; longest text to send

Every watcher runs on its own. Watchers may share the same XMPP account.
Folders are opened read-only: mails stay unread and untouched.
STATE_DIRECTORY (set by systemd) keeps the last seen mail of each watcher.
"""
import asyncio
import email
import email.policy
import json
import logging
import os
import re
import threading
import time
from html.parser import HTMLParser

import slixmpp
import yaml
from imapclient import IMAPClient

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("mail_notifier")

REQUIRED = ("imap_host", "imap_user", "imap_password", "folder",
            "xmpp_jid", "xmpp_password", "recipient")
STATE_DIRECTORY = os.environ["STATE_DIRECTORY"]


# ---------------------------------------------------------------- mail text

class TextExtractor(HTMLParser):
    """Very small HTML-to-text converter: keeps text, turns blocks into lines."""
    BLOCKS = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "table"}

    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0  # inside <script>/<style>

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        elif tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip = max(0, self.skip - 1)
        elif tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def body_text(message, max_chars):
    part = message.get_body(preferencelist=("plain", "html"))
    if part is None:
        return ""
    text = part.get_content()
    if part.get_content_type() == "text/html":
        extractor = TextExtractor()
        extractor.feed(text)
        text = "".join(extractor.parts)
    # Tidy up: trim every line, at most one empty line in a row.
    lines = [" ".join(line.split()) for line in text.splitlines()]
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    if len(text) > max_chars:
        text = text[:max_chars].rstrip() + "…"
    return text


# ---------------------------------------------------------------- one watcher

class Watcher:
    def __init__(self, conf, send):
        missing = [key for key in REQUIRED if not conf.get(key)]
        if missing:
            raise ValueError(f"watcher {conf.get('imap_user')!r}/{conf.get('folder')!r}: "
                             f"missing {', '.join(missing)}")
        self.conf = conf
        self.send = send  # thread-safe function: send(recipient, text)
        self.name = f"{conf['imap_user']}/{conf['folder']}"
        self.log = logging.getLogger(f"mail_notifier[{self.name}]")
        self.blacklist = [re.compile(str(pattern), re.IGNORECASE)
                          for pattern in conf.get("subject_blacklist") or []]
        self.max_chars = int(conf.get("max_chars", 2000))
        safe_name = re.sub(r"[^A-Za-z0-9]+", "_", self.name)
        self.state_file = os.path.join(STATE_DIRECTORY, f"{safe_name}.json")

    def load_state(self):
        try:
            with open(self.state_file) as f:
                return json.load(f)
        except (FileNotFoundError, ValueError):
            return {}

    def save_state(self, state):
        tmp = self.state_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, self.state_file)

    def notification(self, raw):
        """Return the text to send for this mail, or None if it is blacklisted."""
        message = email.message_from_bytes(raw, policy=email.policy.default)
        subject = str(message.get("Subject", "")).strip()
        blocked = next((p.pattern for p in self.blacklist if p.search(subject)), None)
        if blocked:
            self.log.info("Skipped %r (matches %r)", subject, blocked)
            return None
        self.log.info("Forwarding %r", subject)
        return f"📧 {subject or '(no subject)'}\n\n{body_text(message, self.max_chars)}".strip()

    def forward_new_mails(self, client, state):
        uids = [uid for uid in client.search(["UID", f"{state['last_uid'] + 1}:*"])
                if uid > state["last_uid"]]  # "n:*" always returns the last mail
        for uid in sorted(uids):
            raw = client.fetch([uid], ["BODY.PEEK[]"])[uid][b"BODY[]"]
            text = self.notification(raw)
            if text:
                self.send(self.conf["recipient"], text)
            state["last_uid"] = uid
            self.save_state(state)

    def run(self):
        """Runs forever in its own thread; reconnects after any error."""
        conf = self.conf
        while True:
            try:
                with IMAPClient(conf["imap_host"], port=int(conf.get("imap_port", 993)),
                                ssl=True, timeout=60) as client:
                    client.login(conf["imap_user"], str(conf["imap_password"]))
                    info = client.select_folder(conf["folder"], readonly=True)
                    validity = info[b"UIDVALIDITY"]
                    state = self.load_state()
                    if state.get("uidvalidity") != validity:
                        # First start (or the folder was recreated): don't
                        # send the old mails, start from the next one.
                        state = {"uidvalidity": validity,
                                 "last_uid": info[b"UIDNEXT"] - 1}
                        self.save_state(state)
                    self.log.info("Watching")
                    while True:
                        self.forward_new_mails(client, state)
                        # Wait for the server to announce changes; restart IDLE
                        # every 10 minutes, as servers drop long idle connections.
                        client.idle()
                        client.idle_check(timeout=600)
                        client.idle_done()
            except Exception:
                self.log.exception("IMAP error, retrying in 60 s")
                time.sleep(60)


# ---------------------------------------------------------------- XMPP

class NotifierBot(slixmpp.ClientXMPP):
    """One XMPP account; starts its watchers once connected."""

    def __init__(self, jid, password, watcher_confs):
        super().__init__(jid, password)
        self.register_plugin("xep_0199", {"keepalive": True})  # keep connection alive
        self.add_event_handler("session_start", self.on_start)
        self.watcher_confs = watcher_confs
        self.started = False

    async def on_start(self, _event):
        self.send_presence()
        await self.get_roster()
        log.info("Connected as %s", self.boundjid.bare)
        if self.started:  # start the IMAP threads only once
            return
        self.started = True
        loop = asyncio.get_running_loop()

        def send(recipient, text):  # called from the IMAP threads
            loop.call_soon_threadsafe(
                lambda: self.send_message(mto=recipient, mbody=text, mtype="chat"))

        for conf in self.watcher_confs:
            watcher = Watcher(conf, send)
            threading.Thread(target=watcher.run, daemon=True, name=watcher.name).start()


async def main():
    with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "configuration")) as f:
        watchers = (yaml.safe_load(f) or {}).get("watchers") or []
    for conf in watchers:
        Watcher(conf, None)  # check the configuration before connecting

    # One XMPP connection per bot account, shared by its watchers.
    accounts = {}
    for conf in watchers:
        accounts.setdefault((conf["xmpp_jid"], str(conf["xmpp_password"])), []).append(conf)
    bots = [NotifierBot(jid, password, confs) for (jid, password), confs in accounts.items()]
    if not bots:
        log.error("No watchers configured")
        return
    for bot in bots:
        bot.connect()
    # If any connection drops, exit; systemd restarts us.
    await asyncio.wait([asyncio.ensure_future(bot.disconnected) for bot in bots],
                       return_when=asyncio.FIRST_COMPLETED)


asyncio.run(main())
