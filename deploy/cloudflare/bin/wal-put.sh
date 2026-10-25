#!/bin/sh
# archive_command: gzip a WAL segment and upload it to R2 as backup/wal/<name>.gz.
# Forced switches (archive_timeout) produce mostly-empty 16 MB segments, so this
# cuts upload and storage by one to two orders of magnitude.
set -eu
: "${BACKUP_PREFIX:=backup}"
src=$1; name=$2
tmp=$(mktemp /tmp/wal.XXXXXX)
trap 'rm -f "$tmp"' EXIT
gzip -1 -c "$src" > "$tmp"
exec /opt/netbox/bin/r2.sh put "$BACKUP_PREFIX/wal/$name.gz" "$tmp"
