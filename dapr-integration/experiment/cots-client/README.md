# COTS client — Pulsar messaging with nothing but curl

Showcase: **any COTS application that can make an HTTP call** integrates with Apache
Pulsar through the Dapr sidecar. The app needs **no Pulsar SDK, no certificates, no
broker addresses** — it only calls Dapr's publish API:

```
POST http://daprd:3500/v1.0/publish/pulsar-pubsub/<topic>
```

Dapr's built-in Pulsar component (configured in
[../dapr-sidecar/conf/daprPubSub.yaml](../dapr-sidecar/conf/daprPubSub.yaml)) owns the
broker connection, TLS transport, and tenant/namespace addressing — the effective
topic is `persistent://tenant/namespace/<topic>`.

## Run

```bash
../dapr-sidecar/start.sh        # daprd must be up first
docker compose up -d
docker compose logs -f producer # PUBLISHED {"id":"1-1","source":"cots-client",...}
```

Or run the whole experiment at once (platform must be up):
```bash
../start-integration.sh
```

## Throughput

Two modes, both plain curl (see the compose header for all knobs):

```bash
docker compose up -d                                          # loop: 1 msg/s (default)
INTERVAL=0 CONCURRENCY=8 LOG_EVERY=200 docker compose up -d   # loop, max rate
BURST=5000 INTERVAL=5 docker compose up -d                    # burst: one parallel curl per batch
```

**Measured end-to-end** (curl → daprd → built-in component → Pulsar, 2-core machine):

| Mode | Rate | Bottleneck |
|---|---|---|
| Loop, 1 worker | ~80 msg/s | curl process spawn per message |
| Loop, 8 workers (saturation) | **~180 msg/s** | process spawn; >8 workers degrades |
| Burst (`-Z` parallel keep-alive, 50 conns) | **~2,500 msg/s** (peaks 5,000) | CPU/daprd — not curl anymore |

Broker-side verified: `msgInCounter` matched the published count.

Capacity planning (e.g. 15K transactions/period):

| Requirement | Feasible with this curl client? |
|---|---|
| 15K per **annum / day / hour** | ✅ trivially (≤ ~4.2 msg/s) |
| 15K per **minute** (250 msg/s) | ✅ loop mode at saturation, or any burst |
| 15K as a batch | ✅ burst mode: **~3–6 seconds** |
| Sustained 15K **per second** | ❌ use a pooled HTTP load client (hey/wrk/k6) or a Pulsar SDK — the Dapr sidecar is not the limiting factor |

The point of this client is integration simplicity, not raw speed: the same publish
URL works from any language, script, or COTS tool that can issue HTTP requests.
