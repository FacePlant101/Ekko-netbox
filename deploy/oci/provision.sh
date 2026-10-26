#!/bin/sh
# Create the network and the NetBox VM in OCI with the oci CLI (~/.oci/config).
# Safe to re-run: existing resources with the same display names are reused.
#
#   ADMIN_CIDR=203.0.113.7/32 ./provision.sh
#
# ADMIN_CIDR is the only source allowed to SSH in; nothing else is open inbound
# (Cloudflare Tunnel connects outbound). Other settings, with defaults:
#   COMPARTMENT_ID   tenancy root (from ~/.oci/config)
#   NAME             netbox
#   OCPUS / MEMORY_GB / BOOT_GB   2 / 12 / 50  (Always Free: 4 OCPU, 24 GB, 200 GB total)
#   SSH_PUBLIC_KEY   ~/.ssh/oracle_cloud_key.pub
#   REPO_URL / REPO_BRANCH        this repository and the branch checked out here
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
: "${ADMIN_CIDR:?set ADMIN_CIDR to the address allowed to SSH in, e.g. 203.0.113.7/32}"
: "${COMPARTMENT_ID:=$(awk -F= '/^tenancy/{print $2; exit}' "$HOME/.oci/config")}"
: "${NAME:=netbox}"
: "${OCPUS:=2}"
: "${MEMORY_GB:=12}"
: "${BOOT_GB:=50}"
: "${SSH_PUBLIC_KEY:=$HOME/.ssh/oracle_cloud_key.pub}"
: "${REPO_URL:=https://github.com/avassdal/Ekko-netbox.git}"
: "${REPO_BRANCH:=$(git -C "$HERE" rev-parse --abbrev-ref HEAD)}"
SHAPE=VM.Standard.A1.Flex
C="--compartment-id $COMPARTMENT_ID"

# First OCID of a non-terminated resource with this display name, or empty.
find_id() { # $1 = oci subcommand words, $2 = display name, rest = extra args
    cmd=$1; name=$2; shift 2
    # shellcheck disable=SC2086
    oci $cmd list $C --all "$@" \
        --query "data[?\"display-name\"=='$name' && \"lifecycle-state\"!='TERMINATED'] | [0].id" --raw-output 2>/dev/null \
        | grep '^ocid1' || true
}

VCN=$(find_id "network vcn" "$NAME-vcn")
if [ -z "$VCN" ]; then
    echo "creating VCN $NAME-vcn"
    VCN=$(oci network vcn create $C --display-name "$NAME-vcn" --cidr-blocks '["10.42.0.0/16"]' \
        --dns-label "${NAME}vcn" --wait-for-state AVAILABLE --query data.id --raw-output)
fi

IGW=$(find_id "network internet-gateway" "$NAME-igw" --vcn-id "$VCN")
if [ -z "$IGW" ]; then
    echo "creating internet gateway"
    IGW=$(oci network internet-gateway create $C --vcn-id "$VCN" --display-name "$NAME-igw" \
        --is-enabled true --wait-for-state AVAILABLE --query data.id --raw-output)
fi

RT=$(oci network vcn get --vcn-id "$VCN" --query 'data."default-route-table-id"' --raw-output)
oci network route-table update --rt-id "$RT" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" >/dev/null

INGRESS="[{\"protocol\":\"6\",\"source\":\"$ADMIN_CIDR\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}}]"
EGRESS='[{"protocol":"all","destination":"0.0.0.0/0"}]'
SL=$(find_id "network security-list" "$NAME-sl" --vcn-id "$VCN")
if [ -z "$SL" ]; then
    echo "creating security list (SSH from $ADMIN_CIDR only)"
    SL=$(oci network security-list create $C --vcn-id "$VCN" --display-name "$NAME-sl" \
        --ingress-security-rules "$INGRESS" --egress-security-rules "$EGRESS" \
        --wait-for-state AVAILABLE --query data.id --raw-output)
else
    oci network security-list update --security-list-id "$SL" --force \
        --ingress-security-rules "$INGRESS" --egress-security-rules "$EGRESS" >/dev/null
fi

SUBNET=$(find_id "network subnet" "$NAME-subnet" --vcn-id "$VCN")
if [ -z "$SUBNET" ]; then
    echo "creating subnet"
    SUBNET=$(oci network subnet create $C --vcn-id "$VCN" --display-name "$NAME-subnet" \
        --cidr-block 10.42.1.0/24 --dns-label app --route-table-id "$RT" \
        --security-list-ids "[\"$SL\"]" --wait-for-state AVAILABLE --query data.id --raw-output)
fi

INSTANCE=$(find_id "compute instance" "$NAME")
if [ -z "$INSTANCE" ]; then
    IMAGE=$(oci compute image list $C --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
        --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 1 --query 'data[0].id' --raw-output)
    USERDATA=$(mktemp)
    trap 'rm -f "$USERDATA"' EXIT
    sed -e "s#__REPO_URL__#$REPO_URL#" -e "s#__REPO_BRANCH__#$REPO_BRANCH#" "$HERE/cloud-init.yaml" > "$USERDATA"
    # Free A1 capacity is often exhausted in one availability domain but not another.
    for AD in $(oci iam availability-domain list $C --query 'data[].name' --raw-output | tr -d '[]",'); do
        echo "launching $NAME ($SHAPE, $OCPUS OCPU, $MEMORY_GB GB) in $AD from branch $REPO_BRANCH"
        if INSTANCE=$(oci compute instance launch $C --availability-domain "$AD" --display-name "$NAME" \
                --shape "$SHAPE" --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
                --image-id "$IMAGE" --boot-volume-size-in-gbs "$BOOT_GB" --subnet-id "$SUBNET" \
                --assign-public-ip true --ssh-authorized-keys-file "$SSH_PUBLIC_KEY" \
                --user-data-file "$USERDATA" --wait-for-state RUNNING --query data.id --raw-output); then
            break
        fi
        INSTANCE=
    done
    if [ -z "$INSTANCE" ]; then
        echo "launch failed in every availability domain. 'Out of host capacity' means no free A1" >&2
        echo "capacity right now: retry later, or upgrade the tenancy to Pay As You Go." >&2
        exit 1
    fi
fi

IP=$(oci compute instance list-vnics --instance-id "$INSTANCE" --query 'data[0]."public-ip"' --raw-output)
echo "instance: $INSTANCE"
echo "public IP: $IP   ssh -i ${SSH_PUBLIC_KEY%.pub} ubuntu@$IP"
