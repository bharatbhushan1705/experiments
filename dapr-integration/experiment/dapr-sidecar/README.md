# Dapr sidecar → Apache Pulsar (built-in component, authentication disabled)

> **Branch state:** this branch (`dapr-integration`) runs the platform with
> **authentication disabled**, which lets Dapr's **built-in** Pulsar component work —
> no pluggable component, no extra containers, no Go code in the repo.
> The full **mTLS** setup (client-cert auth via a custom pluggable component, verified
> end-to-end) is preserved on branch **`experiment/dapr-pulsar-mtls`**.

This stack is only the messaging middleware — `daprd-producer`/`daprd-consumer` plus their config in
[conf/daprProducerPubSub.yaml](conf/daprProducerPubSub.yaml). The producer lives in
[../cots-client/](../cots-client/); run the whole experiment at once with
[../start-integration.sh](../start-integration.sh).

Both directions run at once; each has its own sidecar and its own topic.

cots-client as producer, on `topic`:
```
 cots-client (curl)                        ../cots-client
    │  POST http://daprd-producer:3500/v1.0/publish/pulsar-pubsub/topic   (bare topic name)
    ▼
 daprd-producer 1.15.4  — BUILT-IN pubsub.pulsar   (conf/daprProducerPubSub.yaml)
    │  pulsar://maas-proxy:6650  = plain transport, NO auth
    ▼
 platform Pulsar (authenticationEnabled=false, plain listeners)
    ──►  effective topic: persistent://tenant/namespace/topic
```

cots-client as consumer, on `cots-topic`: the second sidecar `daprd-consumer`
subscribes ([conf/daprConsumerPubSub.yaml](conf/daprConsumerPubSub.yaml)) and delivers each
message to the cots-client consumer as a plain HTTP POST — the app consumes from
Pulsar by doing nothing but serving a webhook:
```
 pulsar-client (pulsar-perf produce)       persistent://tenant/namespace/cots-topic
    ▼
 platform Pulsar
    ▼  subscription 'cots-consumer'
 daprd-consumer  — same pubsub.pulsar component
    │  POST http://cots-consumer:8080/messages   (raw payload)
    ▼
 cots-client consumer (python http.server)     ../cots-client
```
The subscription is scoped to app-id `cots-consumer`, so only the consumer sidecar
subscribes to `cots-topic`.

## Notes

- pulsar-perf 4.x rejects `-pf` (parses it as `-p f`) — the pulsar-client compose
  uses the long form `--payload-file`.
- Dapr delivers raw Pulsar payloads wrapped in a CloudEvent with `data_base64`,
  even for raw subscriptions — the python consumer decodes it so the log shows the
  actual message text.
- The `cots-consumer` subscription on `cots-topic` is durable;
  [../cleanup-integration.sh](../cleanup-integration.sh) deletes it via the admin
  API so it does not collect backlog while the consumer is stopped.

The built-in component **builds the full topic name itself** from its `tenant`/
`namespace` metadata, so producers publish with the **bare** name (`topic`).

Everything runs **plain** (`pulsar://6650`, `http://8080`): with auth and authz off,
unverified TLS added no real security, and the platform image's TLS listener demanded
client certificates at the handshake (`TLSV1_ALERT_CERTIFICATE_REQUIRED`) regardless
of the auth setting. The TLS variants are kept as comments next to each setting —
re-enable them together with authentication. (For reference, the built-in component
does TLS transport via a `pulsar+ssl://` scheme in `host`; `enableTLS: false` then
means unverified server certs.)

## Why authentication had to be disabled

The built-in component supports only JWT `token` / OAuth2 auth. It has **no
client-certificate fields**, so it cannot authenticate to an mTLS-secured broker.
On this branch the trade-off is: simpler stack, but the broker accepts unauthenticated
connections (TLS still encrypts the transport).

## Upstream contribution plan (bring back mTLS without any of this)

The real fix is ~30 lines in `dapr/components-contrib` (`pubsub/pulsar`): add
`tlsCertFile` / `tlsKeyFile` / `tlsTrustCertsFilePath` / `tlsValidateHostname`
metadata and wire them to `pulsar.NewAuthenticationTLS(cert, key)` +
`ClientOptions.TLSTrustCertsFilePath` — the underlying `pulsar-client-go` already
supports all of it. Once merged and released in daprd, the mTLS setup needs **only
YAML**: re-enable platform auth and add the cert fields to
[conf/daprProducerPubSub.yaml](conf/daprProducerPubSub.yaml) with `type: pubsub.pulsar`.

Branch `experiment/dapr-pulsar-mtls` contains a working, end-to-end-verified reference
implementation of exactly that wiring (as a pluggable component) — its `Init()` code
translates almost 1:1 into the components-contrib patch.

## Run

```bash
../platform/start.sh        # platform up first (authenticationEnabled=false)
./start.sh                  # daprd-producer + daprd-consumer
cd ../cots-client && ./start.sh                # producer + consumer
```

or everything at once, with an end-to-end assertion of both flows:

```bash
../start-integration.sh             # PASS: cots-client -> daprd-producer -> topic -> pulsar-client
                                    # PASS: pulsar-client -> cots-topic -> daprd-consumer -> cots-client
../cleanup-integration.sh clients   # stop the clients, keep the platform
```

### Publish manually

```bash
curl -X POST "http://localhost:3500/v1.0/publish/pulsar-pubsub/topic?metadata.rawPayload=true" \
  -H 'Content-Type: application/json' -d '{"text":"hello from curl"}'
```
