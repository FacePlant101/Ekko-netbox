#!/bin/sh
# Replace the database, media and scripts with a backup from R2.
#   restore.sh export --yes        the export from the Cloudflare deployment (backup/export/LATEST)
#   restore.sh backup --yes        this deployment's latest nightly backup (<BACKUP_PREFIX>/LATEST)
#   restore.sh <prefix>/<ts> --yes a specific backup directory
# Stop netbox and worker first (`docker compose stop netbox worker`); the web
# container applies any pending migrations when it starts again.
set -eu
: "${R2_BUCKET:=netbox-media}"
: "${BACKUP_PREFIX:=oci}"

SOURCE=${1:-}
if [ "${2:-}" != "--yes" ] || [ -z "$SOURCE" ]; then
    echo "usage: restore.sh export|backup|<prefix>/<timestamp> --yes" >&2
    echo "This drops the netbox database and replaces media and scripts." >&2
    exit 2
fi
case "$SOURCE" in
    export) PREFIX=backup/export ;;
    backup) PREFIX=$BACKUP_PREFIX ;;
    *)      PREFIX= ;;
esac
if [ -n "$PREFIX" ]; then
    TS=$(rclone cat "r2:$R2_BUCKET/$PREFIX/LATEST")
    SRC="r2:$R2_BUCKET/$PREFIX/$TS"
else
    SRC="r2:$R2_BUCKET/$SOURCE"
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[restore] fetching $SRC"
rclone copy "$SRC" "$WORK"
[ -s "$WORK/netbox.dump" ] || { echo "[restore] no netbox.dump in $SRC" >&2; exit 1; }
pg_restore --list "$WORK/netbox.dump" >/dev/null

if psql -d postgres -Atc "select 1 from pg_stat_activity where datname = 'netbox' and pid <> pg_backend_pid()" | grep -q 1; then
    echo "[restore] the netbox database is in use; stop netbox and worker first" >&2
    exit 1
fi
echo "[restore] recreating database netbox"
psql -d postgres -v ON_ERROR_STOP=1 -c "drop database if exists netbox" -c "create database netbox owner netbox"
pg_restore --no-owner --no-acl --exit-on-error -j 2 -d netbox "$WORK/netbox.dump"

if [ -s "$WORK/media.tar.gz" ]; then
    echo "[restore] replacing media and scripts"
    find /data/media /data/scripts -mindepth 1 -delete
    tar -xzf "$WORK/media.tar.gz" -C /data
fi
echo "[restore] done: $SRC"
