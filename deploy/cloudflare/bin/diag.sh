#!/bin/sh
# Fixed, read-only diagnostics for GET /__admin/diag. Prints process state and the
# tail of each program log. Takes no arguments and prints no secrets.
export PATH=/opt/venv/bin:/usr/lib/postgresql/15/bin:/usr/local/bin:/usr/bin:/bin
echo "== uptime / load"; uptime 2>/dev/null; echo
echo "== supervisorctl status"; supervisorctl -c /opt/netbox/supervisord.conf status 2>&1; echo
echo "== processes"; ps -eo pid,user,etime,rss,args 2>/dev/null | head -40; echo
echo "== disk"; df -h / /tmp 2>/dev/null; echo
echo "== listening sockets"; (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null || grep -E '^ *[0-9]+: [0-9A-F]+:[0-9A-F]+ 0+:0+ 0A' /proc/net/tcp) | head; echo
echo "== pg_isready"; pg_isready -h 127.0.0.1 -U netbox 2>&1; echo
echo "== pgdata"; ls -la "${PGDATA:-/opt/netbox/pgdata}" 2>&1 | head -8; echo
for f in pg-prepare supervisord postgres redis web rqworker backup; do
    echo "== /tmp/logs/$f.log (tail)"; tail -n 40 "/tmp/logs/$f.log" 2>&1; echo
done
