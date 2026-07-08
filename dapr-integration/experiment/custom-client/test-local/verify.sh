#!/usr/bin/env bash
# End-to-end verification of the custom-client pipeline using only public images.
#
#   ./verify.sh ghostunnel   # DNS-SAN server cert  -> ghostunnel bridge (default)
#   ./verify.sh haproxy      # SPIFFE-URI-only cert -> haproxy bridge (skip hostname)
#
# Stages startup, publishes via the Java app through Dapr + the bridge into an
# mTLS-required Pulsar, and asserts the consumer read the messages back.
set -uo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

BRIDGE="${1:-ghostunnel}"
if [[ "${BRIDGE}" != "ghostunnel" && "${BRIDGE}" != "haproxy" ]]; then
  echo "usage: $0 [ghostunnel|haproxy]"; exit 2
fi
# haproxy is the one that must cope with SPIFFE-URI-only certs, so test it that way.
if [[ "${BRIDGE}" == "haproxy" ]]; then export URI_ONLY=true; else export URI_ONLY=false; fi

DC="docker compose"
say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*"; dump; exit 1; }
dump() { echo "--- daprd ---"; $DC logs --tail=40 daprd 2>/dev/null; echo "--- ${BRIDGE} ---"; $DC --profile "${BRIDGE}" logs --tail=40 "${BRIDGE}" 2>/dev/null; echo "--- custom-client ---"; $DC logs --tail=40 custom-client 2>/dev/null; echo "--- consumer ---"; $DC logs --tail=40 consumer 2>/dev/null; }

say "clean slate (bridge=${BRIDGE}, URI_ONLY=${URI_ONLY})"
$DC --profile ghostunnel --profile haproxy down -v --remove-orphans 2>/dev/null

say "1) generate certs (Pulsar PKI + app keystore)"
$DC up --exit-code-from certs-init certs-init || fail "cert generation failed"
$DC up --exit-code-from app-cert-init app-cert-init || fail "app keystore generation failed"

say "2) start Pulsar (mTLS) and wait until healthy"
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

say "4) start ${BRIDGE} bridge"
$DC --profile "${BRIDGE}" up -d "${BRIDGE}"
sleep 4

say "5) start Dapr sidecar and wait for its health endpoint"
$DC up -d daprd
ok=false
for i in $(seq 1 24); do
  code=$($DC exec -T daprd wget -q -O /dev/null -S http://127.0.0.1:3500/v1.0/healthz 2>&1 | grep -c "204\|200" || true)
  # daprd image may lack wget; fall back to checking logs for "dapr initialized"
  if $DC logs daprd 2>/dev/null | grep -q "dapr initialized"; then ok=true; break; fi
  echo "   waiting for daprd... (${i})"; sleep 3
done
[[ "$ok" == "true" ]] || echo "   (warn) couldn't confirm daprd init from logs; continuing"

say "6) start custom-client (publishes ${PUBLISH_COUNT:-10} messages on startup)"
$DC up -d custom-client

say "7) wait for messages to flow, then assert"
received=0
for i in $(seq 1 30); do
  received=$($DC logs consumer 2>/dev/null | grep -c "hello from custom-client" || true)
  echo "   consumer has seen ${received} message(s) (${i})"
  [[ "$received" -ge 1 ]] && break
  sleep 3
done

echo
echo "--- custom-client (producer) tail ---"
$DC logs --tail=15 custom-client 2>/dev/null | sed 's/^/   /'
echo "--- consumer tail ---"
$DC logs --tail=15 consumer 2>/dev/null | sed 's/^/   /'

if [[ "$received" -ge 1 ]]; then
  printf '\n\033[1;32mPASS: %s messages traversed custom-client -> Dapr -> %s -> mTLS Pulsar -> consumer\033[0m\n' "$received" "$BRIDGE"
  echo "(run '$DC --profile ${BRIDGE} down -v' to clean up)"
  exit 0
else
  fail "no messages reached the consumer"
fi
