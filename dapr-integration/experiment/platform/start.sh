#!/usr/bin/env bash
# Start the platform (Pulsar cluster).
set -euo pipefail

PLATFORM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${PLATFORM_DIR}"

docker network create maas-platform-experiment-network 2>/dev/null || true

echo "[1] docker compose build --no-cache"
docker compose build --no-cache

echo "[2] reset generated identities"
rm -rf "$(dirname "${PLATFORM_DIR}")/.ignore.identities"

echo "[3] docker compose up -d --wait"
docker compose up -d --wait --wait-timeout 300

echo "Platform is up..."
