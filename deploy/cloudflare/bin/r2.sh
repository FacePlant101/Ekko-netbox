#!/bin/sh
# Thin client for the Worker's R2 outbound handler (see src/index.ts).
# The container reaches it over plain HTTP on the virtual host $R2_HOST; the
# Worker turns each call into an R2 binding operation. Usage:
#   r2.sh put  <key> <file>      upload (Content-Length is required, so always a file)
#   r2.sh get  <key> <file>      download, exit 1 if missing
#   r2.sh cat  <key>             print object to stdout, exit 1 if missing
#   r2.sh del  <key>
#   r2.sh list <prefix>          one key per line
# Exit codes: 0 ok, 44 object not found (GET/cat only), 1 any other failure.
set -u
BASE="http://${R2_HOST:-r2.internal}"
fetch() { # $1 key, $2 output file
    code=$(curl -s -o "$2" -w '%{http_code}' "$BASE/$1") || code=000
    case "$code" in
        200) return 0 ;;
        404) rm -f "$2"; return 44 ;;
        *) echo "r2.sh: GET $1 failed (HTTP $code)" >&2; rm -f "$2"; return 1 ;;
    esac
}
case "$1" in
    put)  curl -sfS -T "$3" "$BASE/$2" -o /dev/null ;;
    get)  fetch "$2" "$3" ;;
    cat)  tmp=$(mktemp /tmp/r2cat.XXXXXX); fetch "$2" "$tmp"; rc=$?; [ $rc -eq 0 ] && cat "$tmp"; rm -f "$tmp"; exit $rc ;;
    del)  curl -sfS -X DELETE "$BASE/$2" -o /dev/null ;;
    list) curl -sfS "$BASE/?list=$2" ;;
    *) echo "r2.sh: unknown command $1" >&2; exit 2 ;;
esac
