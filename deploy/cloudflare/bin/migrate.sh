#!/bin/sh
# Bring the database schema and search index up to date. Shared by the web
# program (allinone role) and the web/migrate roles of the entrypoint.
set -eu
cd /opt/netbox/netbox
echo "[migrate] applying database migrations"
python manage.py migrate --no-input
python manage.py remove_stale_contenttypes --no-input
python manage.py reindex --lazy
