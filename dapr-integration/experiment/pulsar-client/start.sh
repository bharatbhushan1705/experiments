#!/usr/bin/env bash
# Start the pulsar-client consumer; 'reverse' also starts the producer.
# Needs the platform up with 6650/8080 published.
set -euo pipefail

CLIENT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${CLIENT_DIR}"

docker network create experimental-maas-client-network 2>/dev/null || true

if [[ "${1:-}" == "reverse" ]]; then
  echo "[1] docker compose --profile reverse up -d --wait"
  docker compose --profile reverse up -d --wait --wait-timeout 300
  echo "pulsar-client is up. Logs: docker compose logs -f consumer producer"
else
  echo "[1] docker compose up -d --wait"
  docker compose up -d --wait --wait-timeout 300
  echo "pulsar-client is up. Logs: docker compose logs -f consumer"
fi
