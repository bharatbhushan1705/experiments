#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

# --profile reverse: 'down' only removes services from active profiles
docker compose --profile reverse down --remove-orphans

echo "dapr-sidecar stopped..."
