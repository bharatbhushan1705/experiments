#!/usr/bin/env bash
# Bring up the Dapr side of the experiment against the running platform cluster.
# Prereqs: the platform is up (../platform/start.sh) so its identities exist under
# ../.ignore.identities. PEM extraction happens in-compose via the same openssl
# utility containers the pulsar-client stack uses (extract-pem.sh).
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

NETWORK="maas-platform-experiment-network"
IDENTITIES_DIR="${IDENTITIES_DIR:-$(dirname "${DIR}")/.ignore.identities}"

echo "[1] ensure network ${NETWORK} exists"
docker network create "${NETWORK}" 2>/dev/null || true

echo "[2] check platform identities (${IDENTITIES_DIR})"
if [[ ! -f "${IDENTITIES_DIR}/admin/keystore.p12" ]]; then
  echo "    ERROR: ${IDENTITIES_DIR}/admin/keystore.p12 not found. Start the platform first (../platform/start.sh)." >&2
  exit 1
fi

if [[ -n "${PLUGGABLE_IMAGE:-}" ]]; then
  echo "[3] using prebuilt pluggable image ${PLUGGABLE_IMAGE} (skipping build)"
  docker pull "${PLUGGABLE_IMAGE}"
else
  echo "[3] build the pluggable component image (offline, vendored)"
  docker compose build pulsar-pluggable
fi

echo "[4] up (utilities extract PEMs, app keystore is generated, stack starts)"
docker compose up -d

echo
echo "Done. Follow the flow with:"
echo "  docker compose logs -f pulsar-pluggable # mTLS connection to Pulsar"
echo "  docker compose logs -f custom-client    # producer: PUBLISHED ..."
echo "  docker compose logs -f consumer         # consumer: got message ..."
