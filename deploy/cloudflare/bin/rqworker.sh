#!/bin/sh
# supervisord program: wait until web.sh has finished migrations, then run the
# RQ worker. The sentinel avoids starting a Django process every few seconds
# while migrations compete for the single vCPU.
set -eu
cd /opt/netbox/netbox
until [ -f /tmp/migrations-done ] && pg_isready -h 127.0.0.1 -U netbox -q; do sleep 5; done
echo "[rqworker] starting"
exec python manage.py rqworker ${RQ_QUEUES:-high default low}
