#!/bin/sh
# Nightly backup to R2: a logical dump of the database plus media and scripts,
# under <bucket>/<BACKUP_PREFIX>/<timestamp>/, published as <BACKUP_PREFIX>/LATEST.
# Keeps the newest BACKUPS_TO_KEEP backups. The R2 remote ("r2") is configured
# entirely through RCLONE_CONFIG_R2_* variables in backup.env.
set -eu
: "${R2_BUCKET:=netbox-media}"
: "${BACKUP_PREFIX:=oci}"
: "${BACKUPS_TO_KEEP:=14}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BASE="r2:$R2_BUCKET/$BACKUP_PREFIX"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[backup] dumping database ($TS)"
pg_dump -Fc --no-owner --no-acl -f "$WORK/netbox.dump"
tar -czf "$WORK/media.tar.gz" -C /data media scripts
ls -l "$WORK" | awk 'NR>1 {print "[backup]", $5, "bytes", $NF}'

rclone copy "$WORK" "$BASE/$TS"
printf '%s' "$TS" | rclone rcat "$BASE/LATEST"
echo "[backup] published $BACKUP_PREFIX/$TS"

rclone lsf --dirs-only "$BASE/" | sed 's#/$##' | sort | head -n -"$BACKUPS_TO_KEEP" | while read -r old; do
    [ -n "$old" ] || continue
    rclone purge "$BASE/$old"
    echo "[backup] pruned $BACKUP_PREFIX/$old"
done
