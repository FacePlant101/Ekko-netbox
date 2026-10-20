#!/bin/sh
# Take a base backup (plus media and scripts) and upload it to R2, wait until the
# WAL needed to make it consistent is archived, publish it as LATEST, then prune
# base backups beyond the newest two and WAL older than the oldest retained one.
set -eu
: "${BACKUP_PREFIX:=backup}"
: "${BASE_BACKUPS_TO_KEEP:=2}"
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
START_WAL=$(tar -xzOf "$WORK/base.tar.gz" backup_label | sed -n 's/^START WAL LOCATION: .* (file \([0-9A-F]*\)).*/\1/p')

tar -czf "$WORK/files.tar.gz" -C "$NETBOX_DIR" media scripts 2>/dev/null || tar -czf "$WORK/files.tar.gz" -T /dev/null
printf '%s' "$START_WAL" > "$WORK/START_WAL"
$R2 put "$BACKUP_PREFIX/base/$TS/base.tar.gz" "$WORK/base.tar.gz"
$R2 put "$BACKUP_PREFIX/base/$TS/files.tar.gz" "$WORK/files.tar.gz"
$R2 put "$BACKUP_PREFIX/base/$TS/START_WAL" "$WORK/START_WAL"

# All WAL up to the end of the backup must be in R2 before it is usable.
/opt/netbox/bin/wait-archived.sh 180 || { echo "[pg-backup] backup not published" >&2; exit 1; }

printf '%s' "$TS" > "$WORK/LATEST"
$R2 put "$BACKUP_PREFIX/base/LATEST" "$WORK/LATEST"
echo "[pg-backup] published $TS (start wal $START_WAL)"

# Keep the newest BASE_BACKUPS_TO_KEEP base backups.
ALL=$($R2 list "$BACKUP_PREFIX/base/" | sed -n "s#^$BACKUP_PREFIX/base/\([0-9TZ]*\)/.*#\1#p" | sort -u)
printf '%s\n' "$ALL" | head -n -"$BASE_BACKUPS_TO_KEEP" | while read -r old; do
    [ -n "$old" ] || continue
    $R2 del "$BACKUP_PREFIX/base/$old/base.tar.gz" || true
    $R2 del "$BACKUP_PREFIX/base/$old/files.tar.gz" || true
    $R2 del "$BACKUP_PREFIX/base/$old/START_WAL" || true
    echo "[pg-backup] pruned base backup $old"
done

# Prune WAL older than the OLDEST retained base backup's start segment, so every
# retained base stays restorable. Skipped when that base predates START_WAL
# objects (the next run, whose retained bases all have one, prunes instead).
OLDEST=$(printf '%s\n' "$ALL" | tail -n "$BASE_BACKUPS_TO_KEEP" | head -n 1)
rc=0; PRUNE_BEFORE=$($R2 cat "$BACKUP_PREFIX/base/$OLDEST/START_WAL" 2>/dev/null) || rc=$?
if [ $rc -ne 0 ] || [ -z "$PRUNE_BEFORE" ]; then
    echo "[pg-backup] no START_WAL for base $OLDEST; skipping WAL prune this run"
    exit 0
fi
$R2 list "$BACKUP_PREFIX/wal/" | while read -r key; do
    name=${key##*/}; name=${name%.gz}
    case "$name" in *.history|'') continue ;; esac
    if [ "$name" \< "$PRUNE_BEFORE" ]; then $R2 del "$key" || true; fi
done
