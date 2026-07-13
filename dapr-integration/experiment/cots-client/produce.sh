#!/bin/sh
# Publish to Pulsar through the Dapr sidecar.
# RATE set (e.g. 1/s, 30/m) = paced mode; RATE unset = burst mode at max throughput.

URL="${DAPR_HTTP}/v1.0/publish/${PUBSUB_NAME}/${TOPIC}?metadata.rawPayload=true"

until curl -fsS "${DAPR_HTTP}/v1.0/healthz" >/dev/null 2>&1; do
  echo "waiting for daprd at ${DAPR_HTTP}..."; sleep 2
done

if [ -n "${RATE}" ]; then
  # curl --rate paces within one invocation, so batches need a few urls each
  N="${LOG_EVERY}"; [ "$N" -lt 10 ] && N=10
  CURL_OPTS="--rate ${RATE}"
  echo "publishing at rate ${RATE} to topic '${TOPIC}' (log every $N msgs)"
else
  N="${BURST}"
  CURL_OPTS="-Z --parallel-max ${PARALLEL_MAX} --parallel-immediate"
  echo "publishing bursts of ${BURST} msgs (parallel-max ${PARALLEL_MAX}) to topic '${TOPIC}'"
fi

# one url line per message to send in a single curl invocation
i=0; while [ "$i" -lt "$N" ]; do echo "url = \"$URL\""; i=$((i+1)); done > /tmp/urls.cfg

S=$(date +%s); b=0; t=0
while :; do
  b=$((b+1))
  BODY="{\"batch\":$b,\"source\":\"cots-client\",\"text\":\"hello from cots-client batch $b\"}"
  if ERR=$(curl -fsS $CURL_OPTS -X POST \
       -H "Content-Type: application/json" -d "$BODY" --config /tmp/urls.cfg 2>&1 >/dev/null); then
    t=$((t+N))
    if [ -n "${RATE}" ]; then
      echo "sent $t msgs total (rate ${RATE})"
    elif [ "$b" -eq 1 ] || [ $((b % LOG_EVERY)) -eq 0 ]; then
      E=$(date +%s); D=$((E-S)); [ "$D" -eq 0 ] && D=1
      echo "burst $b: $t msgs total, ~$((t/D)) msg/s"
    fi
  else
    echo "batch $b: FAILED ($(echo "$ERR" | grep -c .) of $N requests, first: $(echo "$ERR" | head -1))"
    sleep 1
  fi
done
