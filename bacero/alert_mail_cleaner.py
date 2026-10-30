#!/usr/bin/env python3
"""Delete old Alertmanager notifications from the Sent folder of a mailbox.

Alertmanager sends its emails through the personal mailbox, whose server
keeps a copy of each of them in the Sent folder. Every Alertmanager adds
the header

    X-Alertmanager-Host: <host name>

to its emails (see monitoring.nix): this script deletes the mails that
have it, with one of the expected host names, and are older than
KEEP_DAYS. Every other mail is left untouched. Runs once and exits
(started by a systemd timer).

Configuration: the YAML file $CREDENTIALS_DIRECTORY/configuration
(provided by systemd), like this

    imap_host: imap.example.com
    imap_port: 993             # optional, default 993 (TLS)
    imap_user: me@example.com
    imap_password: secret
    folder: Sent               # optional, default: the folder that the
                               # server marks as \\Sent

Environment (set by the NixOS module):
  HEADER     header to look for, e.g. X-Alertmanager-Host
  HOSTS      accepted values of the header, comma separated
  KEEP_DAYS  mails younger than this are kept
  DRY_RUN    "1": only list what would be deleted
"""
import datetime
import email
import email.policy
import logging
import os
import sys

import yaml
from imapclient import IMAPClient
from imapclient.imapclient import SENT

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("alert_mail_cleaner")

HEADER = os.environ["HEADER"]
HOSTS = {h.strip() for h in os.environ["HOSTS"].split(",") if h.strip()}
KEEP_DAYS = int(os.environ["KEEP_DAYS"])
DRY_RUN = os.environ.get("DRY_RUN") == "1"

# Delete in chunks, to keep the IMAP commands short
CHUNK = 200


def load_configuration():
    path = os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "configuration")
    with open(path) as f:
        configuration = yaml.safe_load(f)
    for key in ("imap_host", "imap_user", "imap_password"):
        if not configuration.get(key):
            sys.exit(f"missing `{key}` in the configuration")
    return configuration


def header_value(raw_headers):
    """Value of HEADER in the raw header bytes, or None if missing."""
    message = email.message_from_bytes(raw_headers, policy=email.policy.default)
    value = message.get(HEADER)
    return str(value).strip() if value is not None else None


def chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def main():
    configuration = load_configuration()
    before = datetime.date.today() - datetime.timedelta(days=KEEP_DAYS)

    with IMAPClient(configuration["imap_host"],
                    port=configuration.get("imap_port", 993),
                    ssl=True, timeout=60) as client:
        client.login(configuration["imap_user"], configuration["imap_password"])

        folder = configuration.get("folder") or client.find_special_folder(SENT)
        if folder is None:
            sys.exit("no Sent folder found: set `folder` in the configuration")
        client.select_folder(folder, readonly=DRY_RUN)

        # An empty string matches every mail that has the header (RFC 3501,
        # SEARCH HEADER). BEFORE compares the date the mail was stored.
        candidates = client.search(["HEADER", HEADER, "", "BEFORE", before])
        log.info("%s: %d mails with %s stored before %s",
                 folder, len(candidates), HEADER, before)

        # Double check on the actual headers before deleting anything: some
        # servers implement SEARCH loosely.
        to_delete = []
        request = f"BODY.PEEK[HEADER.FIELDS ({HEADER.upper()} SUBJECT DATE)]"
        for chunk in chunks(candidates, CHUNK):
            for uid, data in client.fetch(chunk, [request]).items():
                # the key of the answer is spelled differently by each
                # server: take the only BODY[...] item
                raw = next((v for k, v in data.items() if k.startswith(b"BODY[")), b"")
                host = header_value(raw)
                message = email.message_from_bytes(raw, policy=email.policy.default)
                if host in HOSTS:
                    to_delete.append(uid)
                    if DRY_RUN:
                        log.info("would delete: [%s] %s - %s",
                                 host, message.get("Date"), message.get("Subject"))
                else:
                    log.warning("skipping mail %s: %s is %r, not one of %s",
                                uid, HEADER, host, sorted(HOSTS))

        if DRY_RUN:
            log.info("dry run: %d mails would be deleted", len(to_delete))
            return
        if not to_delete:
            return

        uidplus = b"UIDPLUS" in client.capabilities()
        for chunk in chunks(to_delete, CHUNK):
            client.delete_messages(chunk)  # sets \Deleted
            if uidplus:
                # removes only these mails
                client.uid_expunge(chunk)
        if not uidplus:
            # also removes the other mails of the folder flagged \Deleted
            log.warning("server without UIDPLUS: plain EXPUNGE")
            client.expunge()
        log.info("deleted %d mails", len(to_delete))


if __name__ == "__main__":
    main()
