#!/bin/sh
# restore_command: fetch backup/wal/<name>.gz from R2 and gunzip it into place.
# Falls back to an uncompressed object for history files or older archives.
set -eu
: "${BACKUP_PREFIX:=backup}"
name=$1; dest=$2
tmp=$(mktemp /tmp/wal.XXXXXX)
trap 'rm -f "$tmp"' EXIT
if /opt/netbox/bin/r2.sh get "$BACKUP_PREFIX/wal/$name.gz" "$tmp"; then
    gunzip -c "$tmp" > "$dest"
elif /opt/netbox/bin/r2.sh get "$BACKUP_PREFIX/wal/$name" "$tmp"; then
    cp "$tmp" "$dest"
else
    exit 1
fi
