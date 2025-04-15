#!/bin/sh

set -o errexit
set -o nounset
set -o pipefail

set -xe

for folder
do
    restic backup \
	   --tag "$folder" \
	   --host "nasus" \
	   --verbose \
	   "$DATA_DIR/$folder"

    # the policy here is to keep the single most recent snapshot of
    # - each of the last seven day
    # - each of the last 5 weeks
    # - each of the last 12 months
    # - each of the last 100 years (one per year)
    restic forget \
           --tag "$folder" \
           --keep-daily 7 \
           --keep-weekly 5 \
           --keep-monthly 12 \
           --keep-yearly 100 \
           --verbose
done

if [ ! -z "$MINIFLUX_TOKEN" ]; then
    # store the OPML list of feeds, for easy imports to new apps
    curl \
	-H "X-Auth-Token: $MINIFLUX_TOKEN" \
	"http://127.0.0.1:$MINIFLUX_PORT/v1/export" | \
	restic backup \
	   --tag "miniflux" \
	   --host "nasus" \
	   --verbose \
	   --stdin-filename feeds.opml \
	   --stdin

    # the policy here is to keep only
    # - the most recent snapshot, for easy restoring of the current status
    # - the single most recent for each of the last 2 months, in the
    #   unlucky case miniflux corrupts the database
    restic forget \
	   --tag "miniflux" \
	   --keep-last 1 \
	   --keep-monthly 2 \
	   --verbose
fi

if [ ! -z "$POSTGRES_BACKUP" ]; then
    pg_dumpall | \
    restic backup \
	   --tag "postgresql" \
	   --host "nasus" \
	   --verbose \
	   --stdin-filename postgres_backup.sql \
	   --stdin

    # the policy here is to keep the single most recent snapshot of
    # - each of the last seven day
    # - each of the last 5 weeks
    # - each of the last 12 months
    # - each of the last 100 years (one per year)
    restic forget \
           --tag "postgresql" \
           --keep-daily 7 \
           --keep-weekly 5 \
           --keep-monthly 12 \
           --keep-yearly 100 \
           --verbose
fi

restic prune --verbose
restic check --verbose
