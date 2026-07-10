#!/usr/bin/env bash
# Start all components in sequence: platform -> pulsar-client -> dapr-sidecar -> cots-client.
#   ./start-integration.sh                 cots-client producer -> pulsar-client consumer
#   ./start-integration.sh consumerMode    pulsar-client producer -> cots-client consumer
set -uo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${DIR}"

MODE="${1:-producerMode}"
[[ "$MODE" == "producerMode" || "$MODE" == "consumerMode" ]] || { echo "usage: $0 [consumerMode]" >&2; exit 2; }

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*"; dump; exit 1; }
running() { docker ps --format '{{.Names}}' | grep "^$1\$" >/dev/null; }
dump() {
  echo "--- daprd ---";    (cd dapr-sidecar && docker compose logs --tail=30 daprd 2>/dev/null | grep -iE "pulsar|component|error" | tail -15)
  if [[ "$MODE" == "consumerMode" ]]; then
    echo "--- daprd-consumer ---"; docker logs --tail=30 daprd-consumer 2>/dev/null | grep -iE "pulsar|component|subscrib|error" | tail -15
    echo "--- producer ---"; docker logs --tail=10 maas-producer 2>/dev/null
    echo "--- consumer ---"; docker logs --tail=10 cots-consumer 2>/dev/null
  else
    echo "--- producer ---"; (cd cots-client && docker compose logs --tail=10 producer 2>/dev/null)
    echo "--- consumer ---"; docker logs --tail=10 maas-consumer 2>/dev/null
  fi
}

say "starting platform"
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

NS="${TENANT:-tenant}/${NAMESPACE:-namespace}"
nsfound=false
for i in $(seq 1 12); do
  if docker run --rm --network maas-platform-experiment-network curlimages/curl:latest \
       -fsS "http://maas-proxy:8080/admin/v2/namespaces/${TENANT:-tenant}" 2>/dev/null | grep "${NS}" >/dev/null; then
    nsfound=true; break
  fi
  echo "   waiting for namespace ${NS}... (${i})"; sleep 5
done
if [[ "$nsfound" != "true" ]]; then
  echo "   metadata-init did not create ${NS}. Check: docker logs metadata-init" >&2
  fail "namespace ${NS} not found on the cluster"
fi
echo "   namespace ${NS} exists"

if [[ "$MODE" == "consumerMode" ]]; then

  say "starting pulsar-client (consumer + producer)"
  if running maas-producer; then
    echo "   already running, skipping"
  else
    ./pulsar-client/start.sh consumerMode
  fi

  say "starting cots-client (http consumer)"
  ./cots-client/start.sh consumerMode

  say "starting dapr-sidecar (daprd + daprd-consumer)"
  ./dapr-sidecar/start.sh consumerMode
  ok=false
  for i in $(seq 1 24); do
    if docker logs daprd-consumer 2>/dev/null | grep "Component loaded: pulsar-pubsub" >/dev/null; then ok=true; break; fi
    echo "   waiting for daprd-consumer... (${i})"; sleep 3
  done
  [[ "$ok" == "true" ]] || fail "daprd-consumer did not load the pulsar-pubsub component"
  echo "   component loaded"

  say "perform check on messages flow (cots-client consumer log)"
  received=0
  for i in $(seq 1 12); do
    received=$(docker logs cots-consumer 2>&1 | grep -c "hello from pulsar-client" || true)
    echo "   consumer received so far: ${received} (${i})"
    [[ "$received" -ge 1 ]] && break
    sleep 5
  done
  [[ "$received" -ge 1 ]] || fail "no messages seen by the cots-client consumer"

  printf '\n\033[1;32mPASS: pulsar-client -> platform Pulsar -> daprd-consumer -> cots-client consumer (%s messages)\033[0m\n' "$received"

else

  say "starting pulsar-client (consumer)"
  if running maas-consumer; then
    echo "   already running, skipping"
  else
    ./pulsar-client/start.sh
  fi

  say "starting dapr-sidecar"
  ./dapr-sidecar/start.sh
  ok=false
  for i in $(seq 1 24); do
    if (cd dapr-sidecar && docker compose logs daprd 2>/dev/null) | grep "Component loaded: pulsar-pubsub" >/dev/null; then ok=true; break; fi
    echo "   waiting for daprd... (${i})"; sleep 3
  done
  [[ "$ok" == "true" ]] || fail "daprd did not load the pulsar-pubsub component"
  echo "   component loaded"

  say "starting cots-client (producer)"
  ./cots-client/start.sh

  say "perform check on messages flow (pulsar-client consumer stats)"
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

fi

echo "Stop and cleanup ./cleanup-integration.sh"
