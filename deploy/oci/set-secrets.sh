#!/bin/sh
# Prompt for the secrets created in the Cloudflare dashboard and write them into
# tunnel.env and backup.env without echoing them. Run it on the VM in a terminal:
#   ssh -t ubuntu@<ip> /opt/netbox-oci/deploy/oci/set-secrets.sh
# Empty input keeps the current value.
set -eu
cd "$(dirname "$0")"

set_var() { # $1 file, $2 variable
    printf '%s: ' "$2"
    stty -echo 2>/dev/null || true
    IFS= read -r VAL || true
    stty echo 2>/dev/null || true
    echo
    [ -n "$VAL" ] || return 0
    touch "$1" && chmod 600 "$1"
    tmp=$(mktemp)
    if grep -q "^$2=" "$1"; then
        VAL="$VAL" awk -v k="$2" 'index($0, k "=") == 1 { print k "=" ENVIRON["VAL"]; next } { print }' "$1" > "$tmp"
    else
        { cat "$1"; printf '%s=%s\n' "$2" "$VAL"; } > "$tmp"
    fi
    cat "$tmp" > "$1"
    rm -f "$tmp"
}

trap 'stty echo 2>/dev/null || true' EXIT INT
set_var tunnel.env TUNNEL_TOKEN
set_var backup.env RCLONE_CONFIG_R2_ACCESS_KEY_ID
set_var backup.env RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
echo "saved; restart with: docker compose up -d"
