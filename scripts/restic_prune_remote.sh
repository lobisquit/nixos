#!/usr/bin/env bash
# Applies the retention policy to the remote (B2) restic repository of a
# host, from a trusted machine.
#
# The hosts back up with a B2 key that cannot delete (services.backupper
# .repositories.remote.prune = false), so that a compromised host cannot
# erase its backups. Forgetting and pruning old snapshots needs the admin
# key, which lives in admin/restic_b2_admin.yaml, encrypted only for the
# personal keys (not for the servers).
#
# usage: scripts/restic_prune_remote.sh <host> [extra restic forget args, e.g. --dry-run]
set -euo pipefail

host="${1:?usage: $0 <host> [--dry-run]}"; shift
cd "$(dirname "$0")/.."

if ! command -v restic >/dev/null; then
    exec nix shell nixpkgs#restic --command "$0" "$host" "$@"
fi

nix_eval() {
    nix --extra-experimental-features 'nix-command flakes' eval --raw \
        ".#nixosConfigurations.$host.config.$1" ${2:+--apply "$2"}
}

# Same retention policy and host name as the host configuration
hostname=$(nix_eval networking.hostName)
keep_args=$(nix_eval services.backupper.repositories.remote.keep \
    'k: builtins.concatStringsSep " " (builtins.attrValues (builtins.mapAttrs (n: v: "--keep-${n} ${toString v}") k))')

# Repository and password from the host secret, B2 credentials from the
# admin secret (they override the host ones). Nothing is written to disk.
set -a
# shellcheck disable=SC1090
source <(sops -d --extract '["restic_remote_configuration"]' "$host/secrets.yaml")
# shellcheck disable=SC1090
source <(sops -d --extract '["restic_b2_admin_environment"]' admin/restic_b2_admin.yaml)
set +a

echo "Repository: $RESTIC_REPOSITORY"
echo "Host:       $hostname"
echo "Policy:     $keep_args"
echo

# shellcheck disable=SC2086
restic forget --verbose --host "$hostname" --group-by host,tags $keep_args --prune "$@"

# a dry run changes nothing, no need to check
case " $* " in *" --dry-run "*|*" -n "*) exit 0 ;; esac
restic check
