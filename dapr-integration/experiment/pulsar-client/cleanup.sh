#!/usr/bin/env bash
# Stop the pulsar-client.
set -euo pipefail

CLIENT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${CLIENT_DIR}"

docker compose down --remove-orphans

docker network rm experimental-maas-client-network 2>/dev/null || true

echo "pulsar-client stopped."
