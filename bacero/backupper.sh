#!/bin/sh

set -o errexit
set -o nounset
set -o pipefail

set -xe

if [ ! -z "$MINIFLUX_BACKUP_ENABLED" ]; then

    # backup the complete miniflux database, for full instance backup
    # and the OPML list of feeds, for easy imports to new apps
    restic backup \
	   --tag "miniflux" \
	   --host "bacero" \
	   --verbose \
	   "$MINIFLUX_BACKUP_FOLDER"

    # the policy here is to keep the single most recent snapshot of
    # - each of the last seven day
    # - each of the last 5 weeks
    # - each of the last 12 months
    # - each of the last 100 years (one per year)
    restic forget \
	   --tag "miniflux" \
	   --keep-daily 7 \
	   --keep-weekly 5 \
	   --keep-monthly 12 \
	   --keep-yearly 100 \
	   --verbose

fi
