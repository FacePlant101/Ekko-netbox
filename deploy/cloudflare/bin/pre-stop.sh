#!/bin/sh
# Called on SIGTERM before supervisord stops Postgres: push the current WAL
# segment to R2 so at most archive_timeout seconds of writes can be lost.
set -u
if pg_isready -h 127.0.0.1 -U netbox -q; then
    END_WAL=$(psql -h 127.0.0.1 -U netbox -d postgres -Atc "select pg_walfile_name(pg_current_wal_lsn())")
    psql -h 127.0.0.1 -U netbox -d postgres -Atc "select pg_switch_wal()" >/dev/null
    i=0
    while [ $i -lt 60 ]; do
        last=$(psql -h 127.0.0.1 -U netbox -d postgres -Atc "select coalesce(last_archived_wal,'') from pg_stat_archiver")
        if [ "$last" = "$END_WAL" ] || [ "$last" \> "$END_WAL" ]; then echo "[pre-stop] WAL $END_WAL archived"; exit 0; fi
        i=$((i + 1)); sleep 1
    done
    echo "[pre-stop] timed out waiting for WAL $END_WAL to archive" >&2
fi
