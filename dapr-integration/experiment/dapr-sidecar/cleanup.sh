#!/usr/bin/env bash
# Stop the Dapr sidecar (daprd) and the optional consumer.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${DIR}"

# --profile consumer so the profile-gated consumer is removed as well
docker compose --profile consumer down --remove-orphans

echo "dapr-sidecar stopped."
