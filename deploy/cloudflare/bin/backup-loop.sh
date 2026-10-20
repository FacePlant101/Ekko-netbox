#!/bin/sh
# supervisord program: first base backup shortly after boot, then on an interval.
set -u
: "${BACKUP_INTERVAL_SECONDS:=21600}"
: "${BACKUP_INITIAL_DELAY_SECONDS:=120}"
until pg_isready -h 127.0.0.1 -U netbox -q; do sleep 2; done
sleep "$BACKUP_INITIAL_DELAY_SECONDS"
while :; do
    if /opt/netbox/bin/pg-backup.sh; then
        sleep "$BACKUP_INTERVAL_SECONDS"
    else
        echo "[backup-loop] backup failed; retrying in 10 minutes" >&2
        sleep 600
    fi
done
