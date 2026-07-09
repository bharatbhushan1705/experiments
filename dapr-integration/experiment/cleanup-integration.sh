#!/usr/bin/env bash
# Stop all components in reverse order: cots-client -> dapr-sidecar -> pulsar-client -> platform.
#
#   ./cleanup-integration.sh            full teardown, including the platform and its networks
#   ./cleanup-integration.sh clients    stop only the clients, keep the platform running
set -uo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${DIR}"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

say "1) cots-client"
./cots-client/cleanup.sh

say "2) dapr-sidecar"
./dapr-sidecar/cleanup.sh

say "3) pulsar-client"
./pulsar-client/cleanup.sh

if [[ "${1:-}" == "clients" ]]; then
  printf '\n\033[1;32mClients stopped. Platform left running.\033[0m\n'
  exit 0
fi

say "4) platform"
./platform/cleanup.sh

printf '\n\033[1;32mAll components stopped.\033[0m\n'
