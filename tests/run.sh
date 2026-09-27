#!/usr/bin/env bash
# Test the access setup in throwaway containers of the distributions customers run.
#   tests/run.sh [image ...]     default: debian:12 ubuntu:24.04
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
images=("$@")
((${#images[@]})) || images=(debian:12 ubuntu:24.04)
status=0

for image in "${images[@]}"; do
    echo "### $image"
    container=$(docker run -d --rm "$image" sleep 600)
    trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
    docker exec "$container" bash -c \
        'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq openssh-server openssh-client sudo procps passwd >/dev/null' \
        || { echo "cannot prepare $image"; exit 1; }
    docker exec "$container" mkdir -p /work
    docker cp "$root/senzu-access-setup.sh" "$container:/work/senzu-access-setup.sh"
    docker cp "$root/tests/inside.sh" "$container:/work/inside.sh"
    docker exec "$container" bash /work/inside.sh || status=1
    docker rm -f "$container" >/dev/null
    trap - EXIT
done
exit "$status"
