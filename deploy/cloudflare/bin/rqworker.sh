#!/bin/sh
# supervisord program: wait until the schema is current, then run the RQ worker.
set -eu
cd /opt/netbox/netbox
until pg_isready -h 127.0.0.1 -U netbox -q && python manage.py migrate --check --no-input >/dev/null 2>&1; do sleep 5; done
echo "[rqworker] starting"
exec python manage.py rqworker ${RQ_QUEUES:-high default low}
