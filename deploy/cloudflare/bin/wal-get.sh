#!/bin/sh
# restore_command: fetch backup/wal/<name>.gz from R2 and gunzip it into place.
# Falls back to an uncompressed object for history files or older archives.
#
# Exit codes matter to Postgres: 1 means "this segment does not exist", which
# ends recovery and promotes. Only a definite 404 may do that. Any other R2
# failure is retried for up to WAL_GET_RETRY_SECONDS and then exits 126, which
# makes Postgres abort recovery instead of promoting with WAL missing.
set -u
: "${BACKUP_PREFIX:=backup}"
: "${WAL_GET_RETRY_SECONDS:=900}"
name=$1; dest=$2
tmp=$(mktemp /tmp/wal.XXXXXX)
trap 'rm -f "$tmp"' EXIT
R2=/opt/netbox/bin/r2.sh

deadline=$(( $(date +%s) + WAL_GET_RETRY_SECONDS ))
while :; do
    $R2 get "$BACKUP_PREFIX/wal/$name.gz" "$tmp"; rc=$?
    if [ $rc -eq 0 ]; then gunzip -c "$tmp" > "$dest"; exit $?; fi
    if [ $rc -eq 44 ]; then
        $R2 get "$BACKUP_PREFIX/wal/$name" "$tmp"; rc=$?
        if [ $rc -eq 0 ]; then cp "$tmp" "$dest"; exit $?; fi
        if [ $rc -eq 44 ]; then exit 1; fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "[wal-get] R2 unreachable for ${WAL_GET_RETRY_SECONDS}s while fetching $name; aborting recovery" >&2
        exit 126
    fi
    sleep 5
done
