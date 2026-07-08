#!/usr/bin/env bash
# End-to-end verification of the pluggable-component design with REAL per-client mTLS
# auth (no anonymousUserRole). Proves:
#   custom-client(Java) -> daprd -> pulsar-pluggable(NewAuthenticationTLS) -> mTLS Pulsar
#   -> consumer reads the messages back.
set -uo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

DC="docker compose"
say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*"; dump; exit 1; }
dump() {
  echo "--- pulsar-pluggable ---"; $DC logs --tail=30 pulsar-pluggable 2>/dev/null
  echo "--- daprd ---";            $DC logs --tail=40 daprd 2>/dev/null | grep -iE "pluggable|pulsar|component|error|initialized" | tail -25
  echo "--- custom-client ---";    $DC logs --tail=20 custom-client 2>/dev/null
  echo "--- consumer ---";         $DC logs --tail=15 consumer 2>/dev/null
}

say "clean slate"
$DC down -v --remove-orphans 2>/dev/null

if [[ -n "${PLUGGABLE_IMAGE:-}" ]]; then
  say "0) using prebuilt pluggable image: ${PLUGGABLE_IMAGE} (skipping build)"
  docker pull "${PLUGGABLE_IMAGE}" || fail "could not pull ${PLUGGABLE_IMAGE}"
else
  say "0) build the pluggable component image"
  $DC build pulsar-pluggable || fail "component build failed (offline vendored build; see README if behind a proxy)"
fi

say "1) generate certs (Pulsar PKI + app keystore)"
$DC up --exit-code-from certs-init certs-init || fail "cert generation failed"
$DC up --exit-code-from app-cert-init app-cert-init || fail "app keystore generation failed"

say "2) start Pulsar (mTLS, auth ENABLED, no anonymous role) and wait until healthy"
$DC up -d pulsar
for i in $(seq 1 48); do
  st=$($DC ps pulsar --format '{{.Health}}' 2>/dev/null)
  echo "   pulsar health: ${st:-?} (${i})"
  [[ "$st" == "healthy" ]] && break
  sleep 5
done
[[ "$($DC ps pulsar --format '{{.Health}}')" == "healthy" ]] || fail "pulsar not healthy"

say "3) start consumer (subscribes @Earliest, auto-creates topic)"
$DC up -d consumer
sleep 8

say "4) start the pluggable component (creates the UDS socket) and give it a moment"
$DC up -d pulsar-pluggable
sleep 6
$DC ps pulsar-pluggable --format '{{.Name}} {{.State}}' | sed 's/^/   /'

say "5) start Dapr sidecar (must discover pulsar-pluggable.sock) and wait for init"
$DC up -d daprd
ok=false
for i in $(seq 1 24); do
  if $DC logs daprd 2>/dev/null | grep -qiE "Component loaded: pulsar-pubsub|dapr initialized"; then ok=true; break; fi
  if $DC logs daprd 2>/dev/null | grep -qiE "couldn't find|failed to (find|init).*pulsar|error.*pluggable"; then
    fail "daprd could not load the pluggable component"
  fi
  echo "   waiting for daprd init... (${i})"; sleep 3
done
[[ "$ok" == "true" ]] || echo "   (warn) couldn't confirm daprd init; continuing to publish anyway"
# show the component actually loaded
$DC logs daprd 2>/dev/null | grep -iE "pulsar-pubsub|pluggable|component loaded|Initialized" | tail -6 | sed 's/^/   /'

say "6) start custom-client (publishes 10 messages via Dapr)"
$DC up -d custom-client

say "7) wait for messages to flow, then assert"
received=0
for i in $(seq 1 30); do
  received=$($DC logs consumer 2>/dev/null | grep -c "hello from custom-client" || true)
  echo "   consumer has seen ${received} message(s) (${i})"
  [[ "$received" -ge 1 ]] && break
  sleep 3
done

echo; echo "--- custom-client (producer) tail ---"
$DC logs --tail=12 custom-client 2>/dev/null | grep -E "PUBLISHED|PUBLISH|HTTPS|Dapr ready" | sed 's/^/   /'
echo "--- consumer tail ---"
$DC logs --tail=6 consumer 2>/dev/null | grep -E "got message|content" | sed 's/^/   /'
echo "--- pluggable component tail ---"
$DC logs --tail=8 pulsar-pluggable 2>/dev/null | sed 's/^/   /'

if [[ "$received" -ge 1 ]]; then
  printf '\n\033[1;32mPASS: %s messages went custom-client -> Dapr -> pluggable(mTLS auth) -> Pulsar -> consumer\033[0m\n' "$received"
  echo "(no anonymousUserRole — the broker authenticated the client cert as a real role)"
  echo "(run '$DC down -v' to clean up)"
  exit 0
else
  fail "no messages reached the consumer"
fi
