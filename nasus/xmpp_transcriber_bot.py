#!/usr/bin/env python3
"""XMPP bot: send it a voice message (or forward one), it replies with the text.

Only accounts of the bot's own server (user@<domain>) are served.

Environment:
  BOT_JID           bot account, e.g. transcriber@lovisotto.it
  WHISPER_MODEL     faster-whisper model name (default: small)
  WHISPER_LANGUAGE  e.g. "it"; empty = auto-detect
  WHISPER_THREADS   CPU cores Whisper may use; 0 = library default (4)
  WHISPER_PROMPT    punctuated sample text that guides the output style
  CREDENTIALS_DIRECTORY/password   bot password (provided by systemd)
"""
import asyncio
import logging
import os
import shutil
import tempfile
import urllib.request
from urllib.parse import urlparse

import slixmpp
from faster_whisper import WhisperModel

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("transcriber")

JID = os.environ["BOT_JID"]
DOMAIN = JID.split("@")[1]
UPLOAD_HOST = f"upload.{DOMAIN}"
with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "password")) as f:
    PASSWORD = f.read().strip()

LANGUAGE = os.environ.get("WHISPER_LANGUAGE") or None
# A short, well-punctuated sample sentence: Whisper copies its style.
PROMPT = os.environ.get("WHISPER_PROMPT") or None
log.info("Loading Whisper model (first start downloads it, may take a while)...")
MODEL = WhisperModel(os.environ.get("WHISPER_MODEL", "small"),
                     device="cpu", compute_type="int8",
                     cpu_threads=int(os.environ.get("WHISPER_THREADS", "0")))
log.info("Model loaded")


def transcribe(url):
    """Plain synchronous code: download the file, run Whisper, return the text."""
    with tempfile.NamedTemporaryFile() as tmp:
        with urllib.request.urlopen(url, timeout=60) as response:
            shutil.copyfileobj(response, tmp)
        tmp.flush()
        segments, _info = MODEL.transcribe(tmp.name, language=LANGUAGE,
                                           initial_prompt=PROMPT)
        return " ".join(segment.text.strip() for segment in segments)


class TranscriberBot(slixmpp.ClientXMPP):
    def __init__(self):
        super().__init__(JID, PASSWORD)
        self.register_plugin("xep_0066")                       # file links (OOB)
        self.register_plugin("xep_0199", {"keepalive": True})  # keep connection alive
        self.register_plugin("xep_0308")                       # message correction
        self.add_event_handler("session_start", self.on_start)
        self.add_event_handler("message", self.on_message)

    async def on_start(self, _event):
        self.send_presence()
        await self.get_roster()
        log.info("Connected as %s, ready", JID)

    async def on_message(self, msg):
        # Only real messages with content, only from users of this server.
        if msg["type"] not in ("chat", "normal") or not msg["body"]:
            return
        if msg["from"].domain != DOMAIN:
            return

        url = (msg["oob"]["url"] or msg["body"]).strip()
        if url.startswith("aesgcm://"):
            msg.reply("This audio is OMEMO-encrypted. Turn off encryption "
                      "in the chat with me and send it again.").send()
            return
        if urlparse(url).hostname != UPLOAD_HOST:
            msg.reply("Send me a voice message or an audio file.").send()
            return

        log.info("Transcribing audio from %s", msg["from"].bare)
        placeholder = msg.reply("⏳ Transcribing…")
        placeholder["id"] = self.new_id()
        placeholder.send()
        try:
            # Run Whisper in a thread so the XMPP connection stays responsive.
            text = await asyncio.to_thread(transcribe, url)
        except Exception as error:
            log.exception("Transcription failed")
            text = f"Error: {error}"

        # Send the result as a correction of the placeholder:
        # the client replaces "Transcribing…" with the text.
        result = msg.reply(text or "(no speech detected)")
        result["id"] = self.new_id()
        result["replace"]["id"] = placeholder["id"]
        result.send()


async def main():
    bot = TranscriberBot()
    bot.connect()
    await bot.disconnected  # if the connection drops, exit; systemd restarts us


asyncio.run(main())
