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

Rate and parallelism are env-driven (see the compose header for all knobs):

```bash
docker compose up -d                                          # default: 1 msg/s
INTERVAL=0 CONCURRENCY=4 LOG_EVERY=200 docker compose up -d   # burst mode
```

Context for capacity planning (e.g. 15K transactions/period):

**Measured** (4 curl workers, `INTERVAL=0`, against a local Pulsar): **~243 msg/s
end-to-end** — 3,655 messages produced *and consumed* in 15 s, i.e. **15K messages in
~61 s**.

| Requirement | Feasible with this curl client? |
|---|---|
| 15K per **annum / day / hour** | ✅ trivially (≤ ~4.2 msg/s) |
| 15K per **minute** (250 msg/s) | ✅ at the measured rate with 4–5 workers |
| Thousands per second (e.g. 15K TPS) | ❌ not with per-message curl processes — use a real HTTP load client (keep-alive connections) or a Pulsar SDK; the Dapr sidecar itself is not the bottleneck |

The point of this client is integration simplicity, not raw speed: the same publish
URL works from any language, script, or COTS tool that can issue HTTP requests.
