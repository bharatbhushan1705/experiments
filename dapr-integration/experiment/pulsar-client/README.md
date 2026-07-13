# pulsar-client — native Pulsar consumer and producer

The native-Pulsar side of both flows, using the platform image's own tooling
(`pulsar-perf`). It proves messages really crossed the platform:

- **maas-consumer** receives everything the cots-client publishes on `topic`
  and logs a throughput summary every 10 seconds.
- **maas-producer** publishes readable text to `cots-topic`, which the Dapr
  consumer sidecar delivers to the cots-client http consumer.

The stack runs on its own network (`experimental-maas-client-network`) and
reaches the platform through host-published ports (`host.docker.internal:6650/8080`).

## Run

```bash
./start.sh
docker logs -f maas-consumer     # Throughput received: N msg --- x msg/s ...
docker logs -f maas-producer     # Throughput produced: ...
./cleanup.sh
```

## Env

| Var | Default | Meaning |
|---|---|---|
| `revision` | — | platform image tag (`ing-maas-pulsar:${revision}`) |
| `tenantName` / `namespaceName` | `tenant` / `namespace` | topic addressing, matching the platform naming |
| `PRODUCE_RATE` | `10` | msgs/s the producer publishes to `cots-topic` — this drives how fast the cots-client consumer receives |

## Notes

- The image's `client.conf` ships baked keystore/auth defaults; both services
  blank every relevant `client_*` key explicitly ([conf/client.conf](conf/client.conf)
  is the plain reference). Commenting an override out re-activates the baked value.
- The commented `openssl-*-utility` services, TLS env variants, and
  [scripts/extract-pem.sh](scripts/extract-pem.sh) are the mTLS variant — kept for
  re-enabling together with platform authentication. The full working mTLS setup
  lives on branch `experiment/dapr-pulsar-mtls`.
- `pulsar-perf` in Pulsar 4.x rejects `-pf`; the compose uses `--payload-file`.
