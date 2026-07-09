#!/usr/bin/env bash
# Bring up the Dapr side of the experiment against the running platform cluster.
# Prereq: the platform is up (../platform/start.sh) with authentication disabled.
# No certs, no build — daprd's built-in Pulsar component connects over TLS transport
# without authentication.
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

NETWORK="maas-platform-experiment-network"

echo "[1] ensure network ${NETWORK} exists"
docker network create "${NETWORK}" 2>/dev/null || true

echo "[2] up"
docker compose up -d

echo
echo "Done. Follow the flow with:"
echo "  docker compose logs -f producer           # PUBLISHED ..."
echo
echo "Optional verification consumer (not started by default):"
echo "  docker compose --profile consumer up -d && docker compose logs -f consumer"
