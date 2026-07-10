#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

# --profile consumerMode: 'down' only removes services from active profiles
docker compose --profile consumerMode down --remove-orphans

echo "dapr-sidecar stopped..."
