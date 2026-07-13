# COTS ↔ Pulsar through Dapr — the experiment in one page

Proof that any COTS application speaking plain HTTP can both **publish to** and
**consume from** Apache Pulsar through Dapr sidecars — no Pulsar SDK, no broker
addresses, no certificates in the app.

Both directions run at once, separated by topic:

```
 produce:  cots-producer ──HTTP──▶ daprd-producer ──▶ topic      ──▶ maas-consumer
 consume:  maas-producer ──▶ cots-topic ──▶ daprd-consumer ──HTTP──▶ cots-consumer
```

| Pair | Producer | Consumer |
|---|---|---|
| cots-client (plain HTTP app) | `cots-producer` — curl | `cots-consumer` — python http.server |
| dapr sidecars | `daprd-producer` — publish API :3500 | `daprd-consumer` — subscribes, POSTs webhooks |
| pulsar-client (native Pulsar) | `maas-producer` — pulsar-perf | `maas-consumer` — pulsar-perf |

## Quickstart

```bash
./start-integration.sh              # start everything in order, assert both flows
./cleanup-integration.sh clients    # stop the clients, keep the platform
./cleanup-integration.sh            # full teardown
```

## Knobs (env vars)

| Var | Component | Meaning |
|---|---|---|
| `RATE` | cots-producer | paced publishing, e.g. `1/s`, `30/m`, `1/h`; unset = max-throughput bursts |
| `BURST` / `PARALLEL_MAX` | cots-producer | burst-mode batch size / parallel connections |
| `LOG_EVERY` | cots producer+consumer | log every Nth burst/message (default 10) |
| `PRODUCE_RATE` | maas-producer | msgs/s published to `cots-topic` (default 10) |
| `TENANT` / `NAMESPACE` / `TOPIC` | all | topic addressing (defaults `tenant`/`namespace`/`topic`) |

Naming note: to change the tenant or namespace, update all three places together —
`TENANT`/`NAMESPACE` for the integration scripts, `tenantName`/`namespaceName` for
platform and pulsar-client, and the values pinned in
[dapr-sidecar/conf/daprProducerPubSub.yaml](dapr-sidecar/conf/daprProducerPubSub.yaml).

## Watching the logs

| Container | Command | Healthy line | Volume knob |
|---|---|---|---|
| `cots-producer` | `docker logs -f cots-producer` | `burst 20: 20000 msgs total, ~2500 msg/s` (or `sent 50 msgs total (rate 1/s)`) | `LOG_EVERY`, `RATE` |
| `cots-consumer` | `docker logs -f cots-consumer` | `#120 12:00:04 /messages hello from pulsar-client` | `LOG_EVERY` (lines), `PRODUCE_RATE` (incoming rate) |
| `daprd-producer` | `docker logs -f daprd-producer` | `HTTP API Called ... code=204` per publish | remove `--enable-api-logging` to silence |
| `daprd-consumer` | `docker logs -f daprd-consumer` | `Connected consumer ... topic=.../cots-topic` at startup, then quiet — deliveries to the app are not API calls | — |
| `maas-consumer` | `docker logs -f maas-consumer` | `Throughput received: N msg --- x msg/s` every 10 s | — |
| `maas-producer` | `docker logs -f maas-producer` | `Throughput produced: ...` every 10 s | `PRODUCE_RATE` |

## Components

- [platform/](platform/) — the Pulsar cluster (authentication disabled on this branch)
- [pulsar-client/](pulsar-client/) — native Pulsar consumer + producer
- [dapr-sidecar/](dapr-sidecar/) — the two daprd sidecars and their config; see its
  [README](dapr-sidecar/README.md) for the architecture, gotchas, and the upstream mTLS plan
- [cots-client/](cots-client/) — the HTTP-only app; see its
  [README](cots-client/README.md) for throughput numbers and a line-by-line walk
  through [produce.sh](cots-client/produce.sh) and [consume.py](cots-client/consume.py)
