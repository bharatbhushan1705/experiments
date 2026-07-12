# COTS client — Pulsar messaging with nothing but HTTP

Showcase: **any COTS application that can make or receive an HTTP call** integrates
with Apache Pulsar through the Dapr sidecar. The app needs **no Pulsar SDK, no
certificates, no broker addresses**.

Both directions run at once, separated by topic:

- **producer** publishes to `topic` by calling Dapr's publish API —
  `POST http://daprd-producer:3500/v1.0/publish/pulsar-pubsub/topic`
- **consumer** receives `cots-topic` messages as plain HTTP POSTs — the consumer
  sidecar subscribes ([../dapr-sidecar/conf/daprConsumerPubSub.yaml](../dapr-sidecar/conf/daprConsumerPubSub.yaml))
  and delivers each message as a webhook to the app. Here that app is a few lines of
  stock python http.server.

Dapr's built-in Pulsar component (configured in
[../dapr-sidecar/conf/daprProducerPubSub.yaml](../dapr-sidecar/conf/daprProducerPubSub.yaml)) owns the
broker connection, TLS transport, and tenant/namespace addressing — the effective
topics are `persistent://tenant/namespace/topic` and `persistent://tenant/namespace/cots-topic`.

## Run

```bash
../dapr-sidecar/start.sh        # sidecars must be up first
./start.sh                      # producer + consumer
docker compose logs -f producer # burst 10: 10000 msgs total, ~2500 msg/s
docker compose logs -f consumer # #10 12:00:01 /messages hello from pulsar-client
```

Both containers log every 10th burst/message; tune with `LOG_EVERY`
(`LOG_EVERY=100 ./start.sh` for calmer logs, `LOG_EVERY=1 ./start.sh` for every line).

Or run the whole experiment at once (platform must be up):
```bash
../start-integration.sh
```

## Throughput

Default is burst mode: endless bursts of `BURST` messages, each burst a single
`curl -Z` invocation multiplexing over `PARALLEL_MAX` keep-alive connections.

```bash
./start.sh                                 # bursts of 1000 (default)
BURST=5000 PARALLEL_MAX=100 ./start.sh
```

Setting `RATE` switches to paced mode — exact rates over one keep-alive
connection (`curl --rate`), from 1 msg every few seconds up to hundreds per second:

```bash
RATE=1/s ./start.sh      # 1 msg/s
RATE=30/m ./start.sh     # one message every 2 seconds
RATE=500/s ./start.sh    # smooth 500 msg/s
./start.sh               # unset RATE = back to burst mode
```

**Measured end-to-end** (curl → daprd → built-in component → Pulsar, 2-core machine):

| Setup | Rate | Bottleneck |
|---|---|---|
| Burst (`-Z` parallel keep-alive, 50 conns) | **~2,500 msg/s** (peaks 5,000) | CPU/daprd — not curl anymore |

Broker-side verified: `msgInCounter` matched the published count.

Capacity planning (e.g. 15K transactions/period):

| Requirement | Feasible with this curl client? |
|---|---|
| 15K per **annum / day / hour** | ✅ trivially (≤ ~4.2 msg/s) |
| 15K per **minute** (250 msg/s) | ✅ any burst setting |
| 15K as a batch | ✅ `BURST=15000`: **~3–6 seconds** |
| Sustained 15K **per second** | ❌ use a pooled HTTP load client (hey/wrk/k6) or a Pulsar SDK — the Dapr sidecar is not the limiting factor |

The point of this client is integration simplicity, not raw speed: the same publish
URL works from any language, script, or COTS tool that can issue HTTP requests.
