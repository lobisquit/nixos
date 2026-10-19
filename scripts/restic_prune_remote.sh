#!/usr/bin/env bash
# Applies the retention policy to the remote (B2) restic repository, for
# every host, from a trusted machine.
#
# The hosts back up with a B2 key that cannot delete (services.backupper
# .repositories.remote.prune = false), so that a compromised host cannot
# erase its backups. Forgetting and pruning old snapshots needs the admin
# key.
#
# Everything comes from admin/restic.yaml, decrypted locally with
# sops: no server and no host configuration is involved. Its
# restic_b2_admin_environment must define
#   RESTIC_REPOSITORY, RESTIC_PASSWORD,
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (the admin key)
#
# usage: scripts/restic_prune_remote.sh [extra restic forget args]
#   extra args, e.g.: --dry-run, or --host nasus to touch one host only
set -euo pipefail

cd "$(dirname "$0")/.."

# Same policy as the default of services.backupper.repositories.<name>.keep
# in shared/backupper.nix: keep them in sync. It is applied separately to
# every host and tag, as the hosts did before (--group-by host,tags).
KEEP_ARGS="${KEEP_ARGS:---keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 100}"

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

echo "Repository: $RESTIC_REPOSITORY"
echo "Policy:     $KEEP_ARGS (per host and tag)"
echo

# shellcheck disable=SC2086
restic forget --verbose --group-by host,tags $KEEP_ARGS --prune "$@"

# a dry run changes nothing, no need to check
case " $* " in *" --dry-run "*|*" -n "*) exit 0 ;; esac
restic check
