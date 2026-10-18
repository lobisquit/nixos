"""One-way mirror of calendars and address books with vdirsyncer.

The collections are listed in a secret file, one per line, with three
tab-separated fields (empty lines and lines starting with # are ignored):

    <type>  <destination folder, relative to DAV_DIR>  <url>

where type is caldav or carddav (a single collection on a DAV server,
accessed with the shared username and password) or ics (a calendar
subscription, no login).

The vdirsyncer configuration is generated at every run in the private
home of the service, then each collection is synced on its own: an error
in one of them does not stop the others, and the script fails at the end
if any failed. A failed sync never touches the files already downloaded.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

STORAGE_TYPES = {"caldav": "caldav", "carddav": "carddav", "ics": "http"}
FILE_EXTENSIONS = {"caldav": ".ics", "carddav": ".vcf", "ics": ".ics"}

DAV_DIR = Path(os.environ["DAV_DIR"])
STATE_DIR = Path(os.environ["STATE_DIR"])
STATUS_DIR = STATE_DIR / "status"
CONFIG_FILE = STATE_DIR / "vdirsyncer.conf"


def read_secret(variable):
    return Path(os.environ[variable]).read_text().strip("\n")


def parse_collections(text):
    """Return {name: (type, folder, url)}; the name identifies the
    collection in vdirsyncer and is derived from the folder."""
    collections = {}
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        fields = [field.strip() for field in line.split("\t")]
        if len(fields) != 3:
            sys.exit(f"Line {number}: expected 3 tab-separated fields, found {len(fields)}")
        kind, folder, url = fields

        if kind not in STORAGE_TYPES:
            sys.exit(f"Line {number}: unknown type {kind!r}, expected one of {', '.join(STORAGE_TYPES)}")
        if not folder or folder.startswith("/") or ".." in Path(folder).parts:
            sys.exit(f"Line {number}: the folder must be a path inside {DAV_DIR}")

        name = re.sub(r"[^a-z0-9]+", "_", folder.lower()).strip("_")
        if name in collections:
            sys.exit(f"Line {number}: folder {folder!r} clashes with another collection")
        collections[name] = (kind, folder, url)

    return collections


def section(header, values):
    # vdirsyncer configuration values are JSON
    lines = [f"[{header}]"] + [f"{key} = {json.dumps(value)}" for key, value in values.items()]
    return "\n".join(lines) + "\n\n"


def write_config(collections):
    needs_login = any(kind != "ics" for kind, _, _ in collections.values())
    if needs_login:
        username = read_secret("USERNAME_FILE")
        password = read_secret("PASSWORD_FILE")

    config = section("general", {"status_path": str(STATUS_DIR)})
    for name, (kind, folder, url) in collections.items():
        remote = {"type": STORAGE_TYPES[kind], "url": url}
        if kind != "ics":
            remote.update(username=username, password=password, read_only=True)

        config += section(f"pair {name}", {
            "a": f"{name}_remote",
            "b": f"{name}_local",
            "collections": None,  # the URL is the collection itself
            "conflict_resolution": "a wins",
            "partial_sync": "revert",  # local changes are undone
        })
        config += section(f"storage {name}_remote", remote)
        config += section(f"storage {name}_local", {
            "type": "filesystem",
            "path": str(DAV_DIR / folder),
            "fileext": FILE_EXTENSIONS[kind],
        })

    # the file contains the password: readable by this user only
    CONFIG_FILE.unlink(missing_ok=True)
    fd = os.open(CONFIG_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(config)


def vdirsyncer(*args):
    env = dict(os.environ, VDIRSYNCER_CONFIG=str(CONFIG_FILE))
    return subprocess.run(["vdirsyncer", *args], env=env).returncode == 0


def sync(name, folder):
    local = DAV_DIR / folder

    # vdirsyncer only syncs into existing folders
    local.mkdir(parents=True, exist_ok=True)

    # A local folder emptied by hand makes vdirsyncer stop, to avoid
    # propagating the deletion: here the local side is just a copy, so
    # forget the previous state and download everything again. (A remote
    # side that looks emptied still stops the sync.)
    if not any(local.iterdir()):
        (STATUS_DIR / f"{name}.items").unlink(missing_ok=True)

    # discovery is cheap with single collections and is needed after
    # every configuration change
    return vdirsyncer("discover", name) and vdirsyncer("sync", name)


def main():
    collections = parse_collections(read_secret("COLLECTIONS_FILE"))
    if not collections:
        sys.exit("No collections configured")

    write_config(collections)

    failed = [folder for name, (_, folder, _) in collections.items() if not sync(name, folder)]
    if failed:
        sys.exit("Sync failed for: " + ", ".join(failed))
    print(f"{len(collections)} collections synced")


if __name__ == "__main__":
    main()
