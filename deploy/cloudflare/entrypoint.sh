#!/bin/sh
# Entrypoint for the NetBox image on Cloudflare Containers.
# NETBOX_ROLE selects what this instance does:
#   web     - run migrations, then serve HTTP with gunicorn (default)
#   worker  - run the RQ worker for background jobs
#   migrate - run migrations and exit
#   manage  - run an arbitrary manage.py command: NETBOX_ROLE=manage <args>
set -eu

cd /opt/netbox/netbox

ROLE="${NETBOX_ROLE:-web}"

run_migrations() {
    echo "[entrypoint] applying database migrations"
    python manage.py migrate --no-input
    python manage.py remove_stale_contenttypes --no-input
    python manage.py reindex --lazy
}

case "$ROLE" in
    web)
        if [ "${SKIP_MIGRATIONS:-0}" != "1" ]; then
            run_migrations
        fi
        echo "[entrypoint] starting gunicorn"
        exec gunicorn -c /opt/netbox/gunicorn_config.py netbox.wsgi
        ;;
    worker)
        # The web instance applies migrations on start. rqworker touches the jobs
        # table immediately, so wait until the schema is current before starting.
        attempts=0
        until python manage.py migrate --check --no-input >/dev/null 2>&1; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge "${MIGRATION_WAIT_ATTEMPTS:-90}" ]; then
                echo "[entrypoint] database not migrated after $attempts checks; giving up" >&2
                exit 1
            fi
            echo "[entrypoint] waiting for database migrations (check $attempts)"
            sleep "${MIGRATION_WAIT_SECONDS:-10}"
        done
        # Minimal readiness endpoint so the Worker can confirm the instance is up
        # (the containers SDK polls a TCP port after start).
        mkdir -p /tmp/worker-health && touch /tmp/worker-health/ok
        python -m http.server "${WORKER_HEALTH_PORT:-8002}" --bind 0.0.0.0 \
            --directory /tmp/worker-health >/dev/null 2>&1 &
        echo "[entrypoint] starting rqworker"
        exec python manage.py rqworker ${RQ_QUEUES:-high default low}
        ;;
    migrate)
        run_migrations
        ;;
    manage)
        exec python manage.py "$@"
        ;;
    *)
        echo "[entrypoint] unknown NETBOX_ROLE: $ROLE" >&2
        exit 1
        ;;
esac
