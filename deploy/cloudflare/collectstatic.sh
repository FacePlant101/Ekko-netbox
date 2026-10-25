#!/bin/sh
# Produce netbox/static (the Workers Static Assets directory) from the container
# image, so CI and workstations need Docker but no Python environment, and the
# served files are exactly what the image contains.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
TAG=${NETBOX_IMAGE_TAG:-netbox-cf:static}

docker build --platform linux/amd64 -f "$HERE/Dockerfile" -t "$TAG" "$ROOT"
CID=$(docker create --platform linux/amd64 "$TAG")
trap 'docker rm -f "$CID" >/dev/null' EXIT
rm -rf "$ROOT/netbox/static"
docker cp "$CID:/opt/netbox/netbox/static" "$ROOT/netbox/static"
echo "static assets written to $ROOT/netbox/static"
