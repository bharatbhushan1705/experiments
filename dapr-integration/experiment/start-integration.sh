#!/usr/bin/env bash
# Start all components in sequence: platform -> pulsar-client -> cots-client -> dapr-sidecar.
# Both flows run at once, separated by topic:
#   cots-client produces:  cots-client -> daprd-producer -> 'topic' -> pulsar-client consumer
#   cots-client consumes:  pulsar-client -> 'cots-topic' -> daprd-consumer -> cots-client consumer
set -uo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${DIR}"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*"; dump; exit 1; }
running() { docker ps --format '{{.Names}}' | grep "^$1\$" >/dev/null; }
wait_for() { # <description> <tries> <pause> <command...>
  local desc=$1 tries=$2 pause=$3; shift 3
  for i in $(seq 1 "$tries"); do
    "$@" && return 0
    echo "   waiting for ${desc}... (${i})"; sleep "$pause"
  done
  return 1
}
proxy_up() { docker exec pulsar-proxy bash -c 'exec 3<>/dev/tcp/localhost/6650' 2>/dev/null; }
ns_exists() {
  docker run --rm --network maas-platform-experiment-network curlimages/curl:latest \
    -fsS "http://maas-proxy:8080/admin/v2/namespaces/${TENANT:-tenant}" 2>/dev/null | grep "${NS}" >/dev/null
}
sidecars_ready() {
  docker logs daprd-producer 2>/dev/null | grep "Component loaded: pulsar-pubsub" >/dev/null \
    && docker logs daprd-consumer 2>/dev/null | grep "Component loaded: pulsar-pubsub" >/dev/null
}
dump() {
  echo "--- daprd-producer ---"; docker logs --tail=30 daprd-producer 2>/dev/null | grep -iE "pulsar|component|error" | tail -15
  echo "--- daprd-consumer ---"; docker logs --tail=30 daprd-consumer 2>/dev/null | grep -iE "pulsar|component|subscrib|error" | tail -15
  echo "--- cots producer ---";  docker logs --tail=10 cots-producer 2>/dev/null
  echo "--- cots consumer ---";  docker logs --tail=10 cots-consumer 2>/dev/null
  echo "--- maas producer ---";  docker logs --tail=10 maas-producer 2>/dev/null
  echo "--- maas consumer ---";  docker logs --tail=10 maas-consumer 2>/dev/null
}

NS="${TENANT:-tenant}/${NAMESPACE:-namespace}"

say "starting platform"
if running pulsar-proxy; then
  echo "   already running, skipping"
else
  ./platform/start.sh
fi
wait_for "proxy port 6650" 30 5 proxy_up || fail "platform proxy not reachable on 6650"
echo "   proxy port 6650 is up"
wait_for "namespace ${NS}" 12 5 ns_exists || fail "namespace ${NS} not found on the cluster (check: docker logs metadata-init)"
echo "   namespace ${NS} exists"

say "starting pulsar-client (consumer + producer)"
if running maas-consumer && running maas-producer; then
  echo "   already running, skipping"
else
  ./pulsar-client/start.sh
fi

say "starting cots-client (producer + consumer)"
./cots-client/start.sh

say "starting dapr-sidecar (daprd-producer + daprd-consumer)"
./dapr-sidecar/start.sh
wait_for "dapr sidecars" 24 3 sidecars_ready || fail "dapr sidecars did not load the pulsar-pubsub component"
echo "   component loaded in both sidecars"

say "perform check on messages flow: topic (pulsar-client consumer stats)"
produced=0
for i in $(seq 1 12); do
  produced=$(docker logs maas-consumer 2>&1 | grep -oE "Throughput received: +[0-9,]+ +msg" | tail -1 | grep -oE "[0-9,]+" | tr -d ',' || true)
  produced=${produced:-0}
  echo "   pulsar-client consumer received so far: ${produced} (${i})"
  [[ "$produced" -ge 1 ]] && break
  sleep 10
done
[[ "$produced" -ge 1 ]] || fail "no messages seen by the pulsar-client consumer on 'topic'"

say "perform check on messages flow: cots-topic (cots-client consumer log)"
consumed=0
for i in $(seq 1 12); do
  # consumer logs every Nth message as '#<total> HH:MM:SS /messages <payload>'
  consumed=$(docker logs cots-consumer 2>&1 | grep "hello from pulsar-client" | tail -1 | grep -oE '^#[0-9]+' | tr -d '#' || true)
  consumed=${consumed:-0}
  echo "   cots-client consumer received so far: ${consumed} (${i})"
  [[ "$consumed" -ge 1 ]] && break
  sleep 5
done
[[ "$consumed" -ge 1 ]] || fail "no messages seen by the cots-client consumer on 'cots-topic'"

printf '\n\033[1;32mPASS: cots-client -> daprd-producer -> topic -> pulsar-client (%s messages)\033[0m\n' "$produced"
printf '\033[1;32mPASS: pulsar-client -> cots-topic -> daprd-consumer -> cots-client (%s messages)\033[0m\n' "$consumed"
echo "Stop and cleanup ./cleanup-integration.sh"
