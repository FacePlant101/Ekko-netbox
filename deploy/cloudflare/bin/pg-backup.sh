#!/bin/sh
# Take a base backup (plus media and scripts) and upload it to R2, wait until the
# WAL needed to make it consistent is archived, publish it as LATEST, then prune
# WAL segments older than this backup and base backups beyond the newest two.
set -eu
: "${BACKUP_PREFIX:=backup}"
R2=/opt/netbox/bin/r2.sh
PGBIN=/usr/lib/postgresql/15/bin
NETBOX_DIR=/opt/netbox/netbox
TS=$(date -u +%Y%m%dT%H%M%SZ)
WORK=/tmp/pg-backup.$$
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

echo "[pg-backup] starting base backup $TS"
"$PGBIN/pg_basebackup" -h 127.0.0.1 -U netbox -D "$WORK/bk" -Ft -z -X none -c fast --no-manifest
mv "$WORK/bk/base.tar.gz" "$WORK/base.tar.gz"

# WAL segment containing the end of the backup; all WAL up to and including it
# must be in R2 before the backup is usable.
END_WAL=$(psql -h 127.0.0.1 -U netbox -d postgres -Atc "select pg_walfile_name(pg_current_wal_lsn())")
psql -h 127.0.0.1 -U netbox -d postgres -Atc "select pg_switch_wal()" >/dev/null
START_WAL=$(tar -xzOf "$WORK/base.tar.gz" backup_label | sed -n 's/^START WAL LOCATION: .* (file \([0-9A-F]*\)).*/\1/p')

tar -czf "$WORK/files.tar.gz" -C "$NETBOX_DIR" media scripts 2>/dev/null || tar -czf "$WORK/files.tar.gz" -T /dev/null
$R2 put "$BACKUP_PREFIX/base/$TS/base.tar.gz" "$WORK/base.tar.gz"
$R2 put "$BACKUP_PREFIX/base/$TS/files.tar.gz" "$WORK/files.tar.gz"

i=0
while :; do
    last=$(psql -h 127.0.0.1 -U netbox -d postgres -Atc "select coalesce(last_archived_wal,'') from pg_stat_archiver")
    if [ "$last" = "$END_WAL" ] || [ "$last" \> "$END_WAL" ]; then break; fi
    i=$((i + 1))
    if [ $i -gt 180 ]; then echo "[pg-backup] WAL $END_WAL not archived after 180s; backup not published" >&2; exit 1; fi
    sleep 1
done

printf '%s' "$TS" > "$WORK/LATEST"
$R2 put "$BACKUP_PREFIX/base/LATEST" "$WORK/LATEST"
echo "[pg-backup] published $TS (start wal $START_WAL)"

# Prune WAL older than this backup's start segment. Timeline history files are kept.
$R2 list "$BACKUP_PREFIX/wal/" | while read -r key; do
    name=${key##*/}; name=${name%.gz}
    case "$name" in *.history|'') continue ;; esac
    if [ "$name" \< "$START_WAL" ]; then $R2 del "$key" || true; fi
done
# Keep the two newest base backups.
$R2 list "$BACKUP_PREFIX/base/" | sed -n "s#^$BACKUP_PREFIX/base/\([0-9TZ]*\)/.*#\1#p" | sort -u | head -n -2 | while read -r old; do
    [ -n "$old" ] || continue
    $R2 del "$BACKUP_PREFIX/base/$old/base.tar.gz" || true
    $R2 del "$BACKUP_PREFIX/base/$old/files.tar.gz" || true
    echo "[pg-backup] pruned base backup $old"
done
