#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

docker compose down --remove-orphans

echo "dapr-sidecar stopped..."
