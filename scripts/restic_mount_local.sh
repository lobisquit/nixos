#!/usr/bin/env bash
# Mounts, read-only, the local restic repository of nasus (the external
# disk, plugged into this PC) in a private folder, to browse or restore
# files. Stays in the foreground: Ctrl-C unmounts and removes the folder.
#
# The disk itself is mounted automatically, read-only, on /mnt/backup_hdd
# (lobisquit-pc/backup_hdd.nix). The password comes from
# admin/restic.yaml, decrypted locally with sops: its
# restic_local_environment must define RESTIC_PASSWORD.
#
# usage: scripts/restic_mount_local.sh [extra restic mount args]
#   extra args, e.g.: --tag Immagini
set -euo pipefail

cd "$(dirname "$0")/.."

REPOSITORY="${RESTIC_LOCAL_REPOSITORY:-/mnt/backup_hdd/home/restic-repo}"

if ! command -v restic >/dev/null; then
    exec nix shell nixpkgs#restic --command "$0" "$@"
fi

# Accessing the path triggers the automount of the disk
if [ ! -f "$REPOSITORY/config" ]; then
    echo "No restic repository in $REPOSITORY: is the backup disk plugged in?" >&2
    exit 1
fi

# Nothing is written to disk: the password goes straight into the environment
set -a
# shellcheck disable=SC1090
source <(sops -d --extract '["restic_local_environment"]' admin/restic.yaml)
set +a
if [ -z "${RESTIC_PASSWORD:-}" ]; then
    echo "RESTIC_PASSWORD is missing in admin/restic.yaml (restic_local_environment)" >&2
    exit 1
fi
export RESTIC_REPOSITORY="$REPOSITORY"

# Private folder: under $XDG_RUNTIME_DIR (tmpfs, only for this user) if
# available, otherwise in /tmp; mktemp creates it with mode 0700
mountpoint=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/restic-local.XXXXXX")

cleanup() {
    # restic unmounts on Ctrl-C; this covers the other exits
    fusermount3 -u "$mountpoint" 2>/dev/null || fusermount -u "$mountpoint" 2>/dev/null || true
    rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT

echo "Repository: $RESTIC_REPOSITORY"
echo "Mounted on: $mountpoint   (hosts/, tags/, snapshots/, ...)"
echo "Press Ctrl-C to unmount."
echo

# --no-lock: the disk is mounted read-only, restic must not try to write
restic mount --no-lock "$@" "$mountpoint"
