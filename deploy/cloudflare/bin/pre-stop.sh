#!/bin/sh
# Called on SIGTERM after the application processes are stopped and before
# Postgres is: push the current WAL segment to R2 so nothing committed is lost.
set -u
if pg_isready -h 127.0.0.1 -U netbox -q; then
    /opt/netbox/bin/wait-archived.sh 60
fi
