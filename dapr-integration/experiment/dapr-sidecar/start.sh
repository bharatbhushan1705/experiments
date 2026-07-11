#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

docker network create maas-platform-experiment-network 2>/dev/null || true

echo "[1] docker compose up -d"
docker compose up -d

echo "daprd and daprd-consumer are up..."
