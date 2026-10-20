#!/bin/sh
# Prepare $PGDATA before Postgres starts: restore the latest base backup from R2
# and replay archived WAL, or initialise a fresh cluster if no backup exists.
set -eu
: "${PGDATA:=/opt/netbox/pgdata}"
: "${BACKUP_PREFIX:=backup}"
R2=/opt/netbox/bin/r2.sh
PGBIN=/usr/lib/postgresql/15/bin
NETBOX_DIR=/opt/netbox/netbox

if [ -s "$PGDATA/PG_VERSION" ]; then
    echo "[pg-prepare] existing data directory found, reusing it"
    exit 0
fi

mkdir -p "$PGDATA" && chmod 700 "$PGDATA"
# A fresh cluster is only acceptable when R2 definitely has no backup (404).
# Any other failure means R2 is unreachable: retry, then abort so the container
# restarts instead of silently starting empty.
attempt=0
while :; do
    rc=0; LATEST=$($R2 cat "$BACKUP_PREFIX/base/LATEST" 2>/tmp/r2-latest.err) || rc=$?
    [ $rc -eq 0 ] || [ $rc -eq 44 ] && break
    attempt=$((attempt + 1))
    if [ $attempt -ge 30 ]; then
        echo "[pg-prepare] cannot reach R2 after $attempt attempts: $(cat /tmp/r2-latest.err)" >&2
        exit 1
    fi
    echo "[pg-prepare] R2 unreachable ($(tr -d '\n' < /tmp/r2-latest.err)); retrying in 10s"
    sleep 10
done

if [ -n "$LATEST" ]; then
    echo "[pg-prepare] restoring base backup $LATEST from R2"
    $R2 get "$BACKUP_PREFIX/base/$LATEST/base.tar.gz" /tmp/base.tar.gz
    tar -xzf /tmp/base.tar.gz -C "$PGDATA" && rm -f /tmp/base.tar.gz
    # Media and scripts: a definite 404 means the backup has none; any other
    # failure must abort rather than start with an empty media directory.
    rc=0; $R2 get "$BACKUP_PREFIX/base/$LATEST/files.tar.gz" /tmp/files.tar.gz || rc=$?
    if [ $rc -eq 0 ]; then
        tar -xzf /tmp/files.tar.gz -C "$NETBOX_DIR" && rm -f /tmp/files.tar.gz
        echo "[pg-prepare] restored media and scripts"
    elif [ $rc -ne 44 ]; then
        echo "[pg-prepare] could not fetch files.tar.gz for $LATEST (rc=$rc); aborting" >&2
        exit 1
    fi
    # Replay every archived WAL segment, then promote. Postgres removes
    # recovery.signal itself once it has promoted.
    touch "$PGDATA/recovery.signal"
    cat >> "$PGDATA/postgresql.auto.conf" <<CONF
restore_command = '/opt/netbox/bin/wal-get.sh %f %p'
recovery_target_timeline = 'latest'
CONF
else
    echo "[pg-prepare] no backup in R2, initialising a new cluster"
    "$PGBIN/initdb" -D "$PGDATA" -U netbox --auth-local=trust --auth-host=trust \
        --encoding=UTF8 --locale=C.UTF-8 >/dev/null
    echo "NEW_CLUSTER=1" > /tmp/pg-prepare.state
fi

# Settings shared by both paths. Postgres only listens on loopback: the only
# clients are gunicorn and rqworker in this same container.
mkdir -p "$PGDATA/conf.d"
cat > "$PGDATA/conf.d/netbox.conf" <<CONF
listen_addresses = '127.0.0.1'
port = 5432
unix_socket_directories = '/tmp'
wal_level = replica
archive_mode = on
archive_command = '/opt/netbox/bin/wal-put.sh %p %f'
archive_timeout = ${PG_ARCHIVE_TIMEOUT:-60}
max_wal_senders = 3
wal_keep_size = 256MB
shared_buffers = ${PG_SHARED_BUFFERS:-512MB}
effective_cache_size = 2GB
log_min_messages = warning
log_checkpoints = off
CONF
grep -q "include_dir = 'conf.d'" "$PGDATA/postgresql.conf" || echo "include_dir = 'conf.d'" >> "$PGDATA/postgresql.conf"
# Trust local connections only (loopback + unix socket).
cat > "$PGDATA/pg_hba.conf" <<CONF
local   all           all                 trust
host    all           all   127.0.0.1/32  trust
host    all           all   ::1/128       trust
local   replication   all                 trust
host    replication   all   127.0.0.1/32  trust
CONF
echo "[pg-prepare] done"
