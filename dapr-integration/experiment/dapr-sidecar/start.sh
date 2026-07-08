#!/usr/bin/env bash
# Bring up the Dapr side of the experiment against the running platform cluster.
# Prereqs: the platform stack is up (../platform/start.sh) so its identities exist
# under ../.ignore.identities, and the experimental docker network exists.
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

NETWORK="maas-multiple-proxies-experimental-network"
IDENTITIES_DIR="${IDENTITIES_DIR:-$(dirname "${DIR}")/.ignore.identities}"
P12_PASSWORD="${P12_PASSWORD:-changeme}"

echo "[1] ensure network ${NETWORK} exists"
docker network create "${NETWORK}" 2>/dev/null || true

echo "[2] extract client cert/key + CA from platform identities (${IDENTITIES_DIR})"
if [[ ! -d "${IDENTITIES_DIR}/admin" ]]; then
  echo "    ERROR: ${IDENTITIES_DIR}/admin not found. Start the platform first (../platform/start.sh)." >&2
  exit 1
fi
mkdir -p "${DIR}/certs"
docker run --rm \
  -e P12_PASSWORD="${P12_PASSWORD}" \
  -v "${IDENTITIES_DIR}:/identities:ro" \
  -v "${DIR}/certs:/out" \
  -v "${DIR}/scripts/prep-certs.sh:/prep.sh:ro" \
  ubuntu:latest bash /prep.sh

echo "[3] build the pluggable component image"
docker compose build pulsar-pluggable

echo "[4] up (app-cert-init generates the app HTTPS keystore, then the stack starts)"
docker compose up -d

echo
echo "Done. Follow the flow with:"
echo "  docker compose logs -f custom-client    # producer: PUBLISHED ..."
echo "  docker compose logs -f consumer         # consumer: got message ..."
echo "  docker compose logs -f pulsar-pluggable # mTLS connection to Pulsar"
