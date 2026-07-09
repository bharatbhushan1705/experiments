#!/usr/bin/env bash
# Bring up the Dapr sidecar against the running platform cluster.
# Prereq: the platform is up (../platform/start.sh) with authentication disabled.
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

NETWORK="maas-platform-experiment-network"

echo "[1] ensure network ${NETWORK} exists"
docker network create "${NETWORK}" 2>/dev/null || true

echo "[2] up (daprd)"
docker compose up -d

echo
echo "Done. Now start the producer:  cd ../cots-client && docker compose up -d"
echo
echo "Optional verification consumer (not started by default):"
echo "  docker compose --profile consumer up -d && docker compose logs -f consumer"
