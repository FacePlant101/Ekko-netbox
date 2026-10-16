#!/bin/sh
# One-shot database import from R2, run by web.sh before migrations when the
# marker object backup/import/READY exists. The marker's content is the dump's
# object name under backup/import/ (plain SQL: *.sql or *.sql.gz; custom format:
# *.dump). An optional backup/import/media.tar.gz is unpacked into the media dir.
#
# The dump is restored into a separate database (netbox_import) and verified
# before it is swapped in; the previous database is kept as netbox_previous so
# the import can be undone. The marker is then renamed to DONE-<timestamp>, so
# the import never runs twice. web.sh runs migrations right afterwards, which is
# what upgrades the imported schema to this NetBox version.
set -eu
: "${BACKUP_PREFIX:=backup}"
R2=/opt/netbox/bin/r2.sh
PSQL="psql -h 127.0.0.1 -U netbox -v ON_ERROR_STOP=1"
NETBOX_DIR=/opt/netbox/netbox
WORK=/tmp/pg-import.$$
TS=$(date -u +%Y%m%dT%H%M%SZ)

rc=0; NAME=$($R2 cat "$BACKUP_PREFIX/import/READY" 2>/dev/null) || rc=$?
if [ $rc -eq 44 ]; then exit 0; fi
if [ $rc -ne 0 ]; then echo "[pg-import] cannot reach R2 to check for a staged import" >&2; exit 1; fi
NAME=$(printf '%s' "$NAME" | tr -d '[:space:]')
[ -n "$NAME" ] || exit 0

echo "[pg-import] importing $NAME into a staging database"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
$R2 get "$BACKUP_PREFIX/import/$NAME" "$WORK/$NAME"

$PSQL -d postgres -Atc "select pg_terminate_backend(pid) from pg_stat_activity where datname='netbox_import' and pid<>pg_backend_pid()" >/dev/null || true
$PSQL -d postgres -c "drop database if exists netbox_import" >/dev/null
$PSQL -d postgres -c "create database netbox_import" >/dev/null

case "$NAME" in
    *.sql.gz) gunzip -c "$WORK/$NAME" | psql -h 127.0.0.1 -U netbox -d netbox_import -q -v ON_ERROR_STOP=0 2> "$WORK/errors.log" >/dev/null || true ;;
    *.sql)    psql -h 127.0.0.1 -U netbox -d netbox_import -q -v ON_ERROR_STOP=0 -f "$WORK/$NAME" 2> "$WORK/errors.log" >/dev/null || true ;;
    *.dump|*.pgdump|*.custom)
              pg_restore -h 127.0.0.1 -U netbox -d netbox_import --no-owner --no-privileges --no-comments -j 2 "$WORK/$NAME" 2> "$WORK/errors.log" || true ;;
    *) echo "[pg-import] unknown dump format: $NAME" >&2; exit 1 ;;
esac
ERRS=$(grep -c -E 'ERROR' "$WORK/errors.log" || true)
echo "[pg-import] restore finished with $ERRS error lines (missing-role and ownership errors are expected)"
grep -E 'ERROR' "$WORK/errors.log" | grep -vE 'role .* does not exist|must be owner|permission denied|already exists' | head -20 || true

TABLES=$($PSQL -d netbox_import -Atc "select count(*) from information_schema.tables where table_schema='public'")
if [ "${TABLES:-0}" -lt 50 ]; then
    echo "[pg-import] only $TABLES tables after restore; leaving netbox untouched" >&2
    exit 1
fi
echo "[pg-import] $TABLES tables; latest migration per app:"
$PSQL -d netbox_import -Atc "select app||' '||name from django_migrations where id in (select max(id) from django_migrations group by app) and app in ('core','dcim','extras','ipam','users') order by app" | sed 's/^/[pg-import]   /'

# Swap: current -> netbox_previous (replacing any older one), staging -> netbox.
# Nobody else may hold the databases while they are renamed.
$PSQL -d postgres -Atc "select pg_terminate_backend(pid) from pg_stat_activity where datname in ('netbox','netbox_previous') and pid<>pg_backend_pid()" >/dev/null || true
$PSQL -d postgres -c "drop database if exists netbox_previous" >/dev/null
$PSQL -d postgres -c "alter database netbox rename to netbox_previous" >/dev/null
$PSQL -d postgres -c "alter database netbox_import rename to netbox" >/dev/null
echo "[pg-import] swapped in; previous database kept as netbox_previous"

if $R2 get "$BACKUP_PREFIX/import/media.tar.gz" "$WORK/media.tar.gz" 2>/dev/null; then
    tar -xzf "$WORK/media.tar.gz" -C "$NETBOX_DIR" && echo "[pg-import] media restored"
fi

printf '%s %s' "$TS" "$NAME" > "$WORK/DONE"
$R2 put "$BACKUP_PREFIX/import/DONE-$TS" "$WORK/DONE"
$R2 del "$BACKUP_PREFIX/import/READY"
echo "[pg-import] done; migrations follow"
