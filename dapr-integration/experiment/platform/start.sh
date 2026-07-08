#!/usr/bin/env bash
set -euo pipefail

echo "Starting platform with docker compose..."

# Resolve script location so this works from any current directory.

PLATFORM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

CURRENT_DIR=$(pwd)

docker network create maas-multiple-proxies-experimental-network || true

echo "[1] docker compose build --no-cache"
cd "${PLATFORM_DIR}"
docker compose build --no-cache
cd "${CURRENT_DIR}"

echo "[2] remove identities (if it exists)"
if [[ -d "${PLATFORM_DIR}/.ignore.identities" ]]; then
  rm -rf "${PLATFORM_DIR}/.ignore.identities"
fi

echo "[3] docker compose up -d"
cd "${PLATFORM_DIR}"
docker compose up -d --wait --wait-timeout 300
cd "${CURRENT_DIR}"

CLIENTS_IDENTITIES_DIR="$(dirname "$PLATFORM_DIR")/client/.ignore.identities"
echo "[4] copy generated identities to ${CLIENTS_IDENTITIES_DIR}"
# Replace destination contents with newly generated identities.
rm -rf "${CLIENTS_IDENTITIES_DIR:?}/"*
mkdir -p "${CLIENTS_IDENTITIES_DIR}"
cp -R "${PLATFORM_DIR}/.ignore.identities/" "${CLIENTS_IDENTITIES_DIR}/"

echo "Platform is setup. You can now run the client to execute the experiment."
