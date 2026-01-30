#!/usr/bin/env bash
# wrapper around sops+age to act as git filter

set -eo pipefail

KEY=$(git config age.private-key)

REPO_ROOT=$(git rev-parse --show-toplevel)
PUB_KEY="$REPO_ROOT/age/recipients.txt"

CMD="${1:?}"
shift || true
case "$CMD" in
    smudge)
        SOPS_AGE_KEY_FILE="$KEY" sops decrypt --input-type yaml --output-type yaml --filename-override "${1:?}" /dev/stdin
        ;;
    clean)
        sops encrypt --input-type yaml --output-type yaml --filename-override "${1:?}" /dev/stdin
        ;;
    textconv)
        cat "${1:?}" || true
        ;;
    *)
        echo "Invalid command '$CMD'"
        exit 1
        ;;
esac
