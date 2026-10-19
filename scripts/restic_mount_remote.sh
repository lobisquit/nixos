#!/usr/bin/env bash
# Mounts, read-only, the remote (B2) restic repository in a private
# folder of this PC, to browse or restore files of every host.
# Stays in the foreground: Ctrl-C unmounts and removes the folder.
#
# Everything comes from admin/restic.yaml, decrypted locally with
# sops: no server and no host configuration is involved. Its
# restic_b2_admin_environment must define
#   RESTIC_REPOSITORY, RESTIC_PASSWORD,
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (the admin key)
#
# usage: scripts/restic_mount_remote.sh [extra restic mount args]
#   extra args, e.g.: --host nasus --tag Documenti
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v restic >/dev/null; then
    exec nix shell nixpkgs#restic --command "$0" "$@"
fi

# Nothing is written to disk: secrets go straight into the environment
set -a
# shellcheck disable=SC1090
source <(sops -d --extract '["restic_b2_admin_environment"]' admin/restic.yaml)
set +a

for var in RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -z "${!var:-}" ]; then
        echo "$var is missing in admin/restic.yaml (restic_b2_admin_environment)" >&2
        exit 1
    fi
done

# Private folder: under $XDG_RUNTIME_DIR (tmpfs, only for this user) if
# available, otherwise in /tmp; mktemp creates it with mode 0700
mountpoint=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/restic-remote.XXXXXX")

# Opens the folder in the file manager as soon as restic has mounted it;
# runs in the background, and failing to open it is not a problem
open_when_mounted() {
    command -v xdg-open >/dev/null || return 0
    for _ in $(seq 120); do
        if mountpoint -q "$mountpoint"; then
            setsid -f xdg-open "$mountpoint" </dev/null >/dev/null 2>&1 || true
            return 0
        fi
        sleep 0.5
    done
}

cleanup() {
    [ -z "${opener:-}" ] || kill "$opener" 2>/dev/null || true
    # restic unmounts on Ctrl-C; this covers the other exits (lazily, in
    # case the file manager is still looking at the folder)
    fusermount3 -uz "$mountpoint" 2>/dev/null || fusermount -uz "$mountpoint" 2>/dev/null || true
    rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT

echo "Repository: $RESTIC_REPOSITORY"
echo "Mounted on: $mountpoint   (hosts/, tags/, snapshots/, ...)"
echo "Press Ctrl-C to unmount (close the file manager window first)."
echo

open_when_mounted &
opener=$!
# --no-lock: browsing does not even write a lock file to the bucket
restic mount --no-lock "$@" "$mountpoint"
