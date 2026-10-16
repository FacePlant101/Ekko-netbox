#!/bin/sh
# Thin client for the Worker's R2 outbound handler (see src/index.ts).
# The container reaches it over plain HTTP on the virtual host $R2_HOST; the
# Worker turns each call into an R2 binding operation. Usage:
#   r2.sh put  <key> <file>      upload (Content-Length is required, so always a file)
#   r2.sh get  <key> <file>      download, exit 1 if missing
#   r2.sh cat  <key>             print object to stdout, exit 1 if missing
#   r2.sh del  <key>
#   r2.sh list <prefix>          one key per line
set -eu
BASE="http://${R2_HOST:-r2.internal}"
case "$1" in
    put)  curl -sfS -T "$3" "$BASE/$2" -o /dev/null ;;
    get)  curl -sf "$BASE/$2" -o "$3" ;;
    cat)  curl -sf "$BASE/$2" ;;
    del)  curl -sfS -X DELETE "$BASE/$2" -o /dev/null ;;
    list) curl -sfS "$BASE/?list=$2" ;;
    *) echo "r2.sh: unknown command $1" >&2; exit 2 ;;
esac
