#!/usr/bin/env bash
# Start the cots-client (curl producer). Needs the dapr-sidecar up.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

docker network create maas-platform-experiment-network 2>/dev/null || true

echo "[1] docker compose up -d"
docker compose up -d

echo "cots-client is up. Logs: docker compose logs -f producer"
