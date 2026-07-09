#!/usr/bin/env bash
# One-shot integration of the whole experiment, against the REAL platform:
#
#   platform (must already be up)          platform/start.sh
#     <- dapr-sidecar  (daprd, built-in pubsub.pulsar)
#     <- cots-client   (curl producer)
#     -> verification consumer (dapr-sidecar, profile "consumer")
#
#   ./start-integration.sh          start everything + assert messages flow end to end
#   ./start-integration.sh down     stop dapr-sidecar + cots-client (platform untouched)
set -uo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${DIR}"

DC="docker compose"
say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*"; dump; exit 1; }
dump() {
  echo "--- daprd ---";    (cd dapr-sidecar && $DC logs --tail=30 daprd 2>/dev/null | grep -iE "pulsar|component|error" | tail -20)
  echo "--- producer ---"; (cd cots-client && $DC logs --tail=15 producer 2>/dev/null)
  echo "--- consumer ---"; (cd dapr-sidecar && $DC --profile consumer logs --tail=10 consumer 2>/dev/null)
}

if [[ "${1:-}" == "down" ]]; then
  (cd cots-client && $DC down --remove-orphans)
  (cd dapr-sidecar && $DC --profile consumer down --remove-orphans)
  echo "dapr-sidecar + cots-client stopped (platform left running)."
  exit 0
fi

say "1) platform must be running"
if ! docker ps --format '{{.Names}}' | grep -q '^pulsar-proxy$'; then
  echo "   ERROR: platform proxy (pulsar-proxy) is not running. Start it first: platform/start.sh" >&2
  exit 1
fi
docker network create maas-platform-experiment-network 2>/dev/null || true
echo "   platform proxy is up"

say "2) start dapr-sidecar (daprd) + verification consumer"
(cd dapr-sidecar && $DC --profile consumer up -d)

say "3) wait for daprd to load the Pulsar component"
ok=false
for i in $(seq 1 24); do
  if (cd dapr-sidecar && $DC logs daprd 2>/dev/null) | grep -q "Component loaded: pulsar-pubsub"; then ok=true; break; fi
  echo "   waiting for daprd... (${i})"; sleep 3
done
[[ "$ok" == "true" ]] || fail "daprd did not load the pulsar-pubsub component"
echo "   Component loaded: pulsar-pubsub (pubsub.pulsar/v1)"

say "4) start cots-client producer"
(cd cots-client && $DC up -d)

say "5) assert messages reach the consumer"
received=0
for i in $(seq 1 30); do
  received=$( (cd dapr-sidecar && $DC --profile consumer logs consumer 2>/dev/null) | grep -c "hello from cots-client" || true)
  echo "   consumer has seen ${received} message(s) (${i})"
  [[ "$received" -ge 3 ]] && break
  sleep 3
done
[[ "$received" -ge 1 ]] || fail "no messages reached the consumer"

echo; echo "--- producer tail ---"
(cd cots-client && $DC logs --tail=4 producer 2>/dev/null) | grep -E "PUBLISHED|publishing" | sed 's/^/   /'
echo "--- consumer tail ---"
(cd dapr-sidecar && $DC --profile consumer logs --tail=4 consumer 2>/dev/null) | grep -E "got message|content" | sed 's/^/   /'

printf '\n\033[1;32mPASS: %s messages flowed cots-client(curl) -> daprd(pubsub.pulsar) -> platform Pulsar -> consumer\033[0m\n' "$received"
echo "Producer keeps running (1 msg/s by default; see cots-client/README.md for burst knobs)."
echo "Stop everything except the platform:  ./start-integration.sh down"
