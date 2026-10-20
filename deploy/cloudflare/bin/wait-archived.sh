#!/bin/sh
# Switch to a new WAL segment and wait until the segment that was current (and
# everything before it) has been archived to R2. Shared by pg-backup.sh and
# pre-stop.sh. Usage: wait-archived.sh <timeout-seconds>
set -u
timeout=${1:-60}
PSQL="psql -h 127.0.0.1 -U netbox -d postgres -Atc"
end_wal=$($PSQL "select pg_walfile_name(pg_current_wal_lsn())") || exit 1
$PSQL "select pg_switch_wal()" >/dev/null || exit 1
i=0
while [ "$i" -lt "$timeout" ]; do
    last=$($PSQL "select coalesce(last_archived_wal,'') from pg_stat_archiver")
    # Compare on the 24-character segment name so a history file such as
    # <segment>.00000028.backup does not count as a later segment.
    if [ "${last%%.*}" = "$end_wal" ] || [ "${last%%.*}" \> "$end_wal" ]; then
        echo "[wait-archived] WAL $end_wal archived"
        exit 0
    fi
    i=$((i + 1)); sleep 1
done
echo "[wait-archived] timed out after ${timeout}s waiting for WAL $end_wal" >&2
exit 1
