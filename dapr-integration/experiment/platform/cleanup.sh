#!/usr/bin/env bash
# Stop the platform and remove generated identities.
set -euo pipefail

PLATFORM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${PLATFORM_DIR}"

docker compose down --remove-orphans

rm -rf "$(dirname "${PLATFORM_DIR}")/.ignore.identities"

# only removable once dapr-sidecar and cots-client are down too
docker network rm maas-platform-experiment-network 2>/dev/null || true

echo "Platform stopped."
