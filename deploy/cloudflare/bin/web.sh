#!/bin/sh
# supervisord program: wait for Postgres, migrate, serve.
set -eu
cd /opt/netbox/netbox
until pg_isready -h 127.0.0.1 -U netbox -q; do sleep 1; done
until psql -h 127.0.0.1 -U netbox -d postgres -Atc "select 1" >/dev/null 2>&1; do sleep 1; done
psql -h 127.0.0.1 -U netbox -d postgres -Atc "select 1 from pg_database where datname='netbox'" | grep -q 1 || \
    psql -h 127.0.0.1 -U netbox -d postgres -c "create database netbox" >/dev/null
echo "[web] applying database migrations"
python manage.py migrate --no-input
python manage.py remove_stale_contenttypes --no-input
python manage.py reindex --lazy
echo "[web] starting gunicorn"
exec gunicorn -c /opt/netbox/gunicorn_config.py netbox.wsgi
