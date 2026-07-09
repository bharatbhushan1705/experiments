#!/usr/bin/env bash
# Start all components in sequence: platform -> pulsar-client -> dapr-sidecar -> cots-client.
# Each component that is already running is skipped.
#
#   ./start-integration.sh          start everything, then check messages flow
#   ./start-integration.sh down     stop everything except the platform
set -uo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${DIR}"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*"; dump; exit 1; }
running() { docker ps --format '{{.Names}}' | grep -q "^$1\$"; }
dump() {
  echo "--- daprd ---";    (cd dapr-sidecar && docker compose logs --tail=30 daprd 2>/dev/null | grep -iE "pulsar|component|error" | tail -15)
  echo "--- producer ---"; (cd cots-client && docker compose logs --tail=10 producer 2>/dev/null)
  echo "--- consumer ---"; docker logs --tail=10 maas-consumer 2>/dev/null
}

if [[ "${1:-}" == "down" ]]; then
  (cd cots-client && docker compose down --remove-orphans)
  (cd dapr-sidecar && docker compose --profile consumer down --remove-orphans)
  (cd pulsar-client && docker compose down --remove-orphans)
  echo "Stopped cots-client, dapr-sidecar, pulsar-client. Platform left running."
  exit 0
fi

say "1) platform"
if running pulsar-proxy; then
  echo "   already running, skipping"
else
  ./platform/start.sh
fi
for i in $(seq 1 30); do
  docker exec pulsar-proxy bash -c 'exec 3<>/dev/tcp/localhost/6650' 2>/dev/null && { echo "   proxy port 6650 is up"; break; }
  echo "   waiting for proxy... (${i})"; sleep 5
done
docker exec pulsar-proxy bash -c 'exec 3<>/dev/tcp/localhost/6650' 2>/dev/null || fail "platform proxy not reachable on 6650"

say "2) pulsar-client (consumer)"
if running maas-consumer; then
  echo "   already running, skipping"
else
  ./pulsar-client/start.sh
fi

say "3) dapr-sidecar"
./dapr-sidecar/start.sh
ok=false
for i in $(seq 1 24); do
  if (cd dapr-sidecar && docker compose logs daprd 2>/dev/null) | grep -q "Component loaded: pulsar-pubsub"; then ok=true; break; fi
  echo "   waiting for daprd... (${i})"; sleep 3
done
[[ "$ok" == "true" ]] || fail "daprd did not load the pulsar-pubsub component"
echo "   component loaded"

say "4) cots-client (producer)"
./cots-client/start.sh

say "5) check messages flow (pulsar-client consumer stats)"
received=0
for i in $(seq 1 12); do
  received=$(docker logs maas-consumer 2>&1 | grep -oE "Throughput received: +[0-9,]+ +msg" | tail -1 | grep -oE "[0-9,]+" | tr -d ',' || true)
  received=${received:-0}
  echo "   consumer received so far: ${received} (${i})"
  [[ "$received" -ge 1 ]] && break
  sleep 10
done
[[ "$received" -ge 1 ]] || fail "no messages seen by the pulsar-client consumer"

printf '\n\033[1;32mPASS: cots-client -> daprd -> platform Pulsar -> pulsar-client consumer (%s messages)\033[0m\n' "$received"
echo "Stop everything except the platform:  ./start-integration.sh down"
