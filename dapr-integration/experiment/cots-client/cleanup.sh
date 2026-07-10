#!/usr/bin/env bash
# Stop the cots-client.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

# profiles: 'down' only removes services from active profiles
docker compose --profile producerMode --profile consumerMode down --remove-orphans

echo "cots-client stopped..."
