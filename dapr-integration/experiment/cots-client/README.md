# COTS client — Pulsar messaging with nothing but HTTP

Showcase: **any COTS application that can make or receive an HTTP call** integrates
with Apache Pulsar through the Dapr sidecar. The app needs **no Pulsar SDK, no
certificates, no broker addresses**.

Two modes, one per direction:

- **producerMode** (forward flow): the app publishes by calling Dapr's publish API —
  `POST http://daprd:3500/v1.0/publish/pulsar-pubsub/<topic>`
- **consumerMode** (reverse flow): the app consumes by receiving plain HTTP POSTs —
  the consumer sidecar subscribes to the topic and delivers each message as a webhook
  to the app. Here that app is a few lines of stock python http.server.

Dapr's built-in Pulsar component (configured in
[../dapr-sidecar/conf/daprPubSub.yaml](../dapr-sidecar/conf/daprPubSub.yaml)) owns the
broker connection, TLS transport, and tenant/namespace addressing — the effective
topic is `persistent://tenant/namespace/<topic>`.

## Run

```bash
../dapr-sidecar/start.sh                       # daprd must be up first
docker compose --profile producerMode up -d    # or: ./start.sh
docker compose logs -f producer                # burst 1: 1000 msgs total, ~2500 msg/s
```

Consumer (reverse flow — subscription and delivery handled by
[../dapr-sidecar/conf/subscription.yaml](../dapr-sidecar/conf/subscription.yaml)):
```bash
docker compose --profile consumerMode up -d    # or: ./start.sh consumerMode
docker compose logs -f consumer                # 12:00:01 /messages hello from pulsar-client
```

Or run the whole experiment at once (platform must be up):
```bash
../start-integration.sh                 # forward: curl producer -> pulsar-client consumer
../start-integration.sh consumerMode    # reverse: pulsar-client producer -> http consumer
```

## Throughput

The producer has one fixed mode: endless bursts of `BURST` messages, each burst a
single `curl -Z` invocation multiplexing over `PARALLEL_MAX` keep-alive connections.

```bash
./start.sh                                 # bursts of 1000 (default)
BURST=5000 PARALLEL_MAX=100 ./start.sh
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
