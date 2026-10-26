#!/bin/sh
# One-shot logical export for moving NetBox off Cloudflare (see deploy/oci/README.md):
# a pg_dump of the live database plus media and scripts, uploaded to R2 under
# backup/export/<timestamp>/ and published as backup/export/LATEST. Run by the
# Worker's POST /__admin/export. A logical dump restores into any Postgres version
# on any CPU architecture, unlike the physical base backups.
set -eu
: "${BACKUP_PREFIX:=backup}"
R2=/opt/netbox/bin/r2.sh
PGBIN=/usr/lib/postgresql/15/bin
NETBOX_DIR=/opt/netbox/netbox
TS=$(date -u +%Y%m%dT%H%M%SZ)
WORK=/tmp/pg-export.$$
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

echo "[pg-export] dumping database netbox ($TS)"
"$PGBIN/pg_dump" -h 127.0.0.1 -U netbox -d netbox -Fc --no-owner --no-acl -f "$WORK/netbox.dump"
tar -czf "$WORK/media.tar.gz" -C "$NETBOX_DIR" media scripts 2>/dev/null || tar -czf "$WORK/media.tar.gz" -T /dev/null
ls -l "$WORK/netbox.dump" "$WORK/media.tar.gz" | awk '{print "[pg-export]", $5, "bytes", $NF}'

$R2 put "$BACKUP_PREFIX/export/$TS/netbox.dump" "$WORK/netbox.dump"
$R2 put "$BACKUP_PREFIX/export/$TS/media.tar.gz" "$WORK/media.tar.gz"
printf '%s' "$TS" > "$WORK/LATEST"
$R2 put "$BACKUP_PREFIX/export/LATEST" "$WORK/LATEST"
echo "[pg-export] published $BACKUP_PREFIX/export/$TS"
