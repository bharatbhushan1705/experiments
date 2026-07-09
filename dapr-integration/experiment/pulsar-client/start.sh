#!/usr/bin/env bash
set -euo pipefail

echo "Starting platform with docker compose..."

# Resolve script location so this works from any current directory.

CLIENT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

CURRENT_DIR=$(pwd)

docker network create experimental-maas-client-network || true
echo "[1] docker compose up -d"
cd "${CLIENT_DIR}"
docker compose up -d --wait --wait-timeout 300
cd "${CURRENT_DIR}"
