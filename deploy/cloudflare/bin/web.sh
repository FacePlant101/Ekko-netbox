#!/bin/sh
# supervisord program: wait for Postgres, import if staged, migrate, serve.
set -eu
cd /opt/netbox/netbox
rm -f /tmp/migrations-done
until pg_isready -h 127.0.0.1 -U netbox -q; do sleep 1; done
until psql -h 127.0.0.1 -U netbox -d postgres -Atc "select 1" >/dev/null 2>&1; do sleep 1; done
psql -h 127.0.0.1 -U netbox -d postgres -Atc "select 1 from pg_database where datname='netbox'" | grep -q 1 || \
    psql -h 127.0.0.1 -U netbox -d postgres -c "create database netbox" >/dev/null
# One-shot import of a dump staged in R2 (see bin/pg-import.sh); no-op otherwise.
# A failed import must not take the web tier down: log it and keep serving the
# current database (pg-import.sh marks the staged import as FAILED).
if ! /opt/netbox/bin/pg-import.sh; then
    echo "[web] staged import failed; continuing with the current database" >&2
fi
/opt/netbox/bin/migrate.sh
# Tells rqworker.sh the schema is current (cheaper than polling migrate --check).
touch /tmp/migrations-done
# Optional bootstrap of the first admin account (Worker secrets NETBOX_SUPERUSER_*).
# Idempotent: existing users are left untouched, so the secrets can stay set.
if [ -n "${NETBOX_SUPERUSER_PASSWORD:-}" ]; then
    python manage.py shell -c "
import os
from users.models import User
name = os.environ.get('NETBOX_SUPERUSER_NAME', 'admin')
if not User.objects.filter(username=name).exists():
    User.objects.create_superuser(name, os.environ.get('NETBOX_SUPERUSER_EMAIL', ''), os.environ['NETBOX_SUPERUSER_PASSWORD'])
    print(f'[web] created superuser {name}')
else:
    print(f'[web] superuser {name} already exists')
"
fi
echo "[web] starting gunicorn"
exec gunicorn -c /opt/netbox/gunicorn_config.py netbox.wsgi
