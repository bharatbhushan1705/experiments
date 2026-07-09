# Dapr → Apache Pulsar (built-in component, authentication disabled)

> **Branch state:** this branch (`dapr-integration`) runs the platform with
> **authentication disabled**, which lets Dapr's **built-in** Pulsar component work —
> no pluggable component, no extra containers, no Go code in the repo.
> The full **mTLS** setup (client-cert auth via a custom pluggable component, verified
> end-to-end) is preserved on branch **`experiment/dapr-pulsar-mtls`**.

```
 producer (curl loop, 1 msg/s)
    │  POST http://daprd:3500/v1.0/publish/pulsar-pubsub/topic     (bare topic name)
    ▼
 daprd 1.15.4  — BUILT-IN pubsub.pulsar (daprPubSub.yaml)
    │  pulsar+ssl://maas-proxy:6651  = TLS transport, cert NOT verified, NO auth
    ▼
 platform Pulsar (authenticationEnabled=false)
    ──►  effective topic: persistent://tenant/namespace/topic
    ──►  (optional) profile-gated verification consumer
```

The built-in component **builds the full topic name itself** from its `tenant`/
`namespace` metadata, so the producer publishes with the **bare** name (`topic`) —
no URL-encoding needed. TLS semantics (verified against components-contrib source):
the `pulsar+ssl://` scheme in `host` turns on TLS transport, and `enableTLS: false`
sets `TLSAllowInsecureConnection=true`, i.e. the platform's self-signed/SPIFFE server
cert is accepted unverified — the same posture as `client.conf`.

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
YAML**: re-enable platform auth and add the cert fields to [daprPubSub.yaml](daprPubSub.yaml)
with `type: pubsub.pulsar`.

Branch `experiment/dapr-pulsar-mtls` contains a working, end-to-end-verified reference
implementation of exactly that wiring (as a pluggable component) — the `Init()` code
there translates almost 1:1 into the components-contrib patch.

## Files

| Path | What |
|---|---|
| [daprPubSub.yaml](daprPubSub.yaml) | Built-in `pubsub.pulsar`: host (TLS transport), tenant/namespace. |
| [docker-compose.yaml](docker-compose.yaml) | daprd + curl producer (+ optional profile-gated consumer). |
| [start.sh](start.sh) | Network check + `docker compose up`. |
| [verify-local/](verify-local/) | Self-contained proof against a stock TLS-no-auth Pulsar standalone. |

## Run it — self-contained proof

```bash
cd verify-local && ./verify.sh
# PASS: N messages went producer(curl) -> Dapr(built-in pubsub.pulsar) -> TLS Pulsar (no auth) -> consumer
```

## Run it — against the platform

```bash
../platform/start.sh      # platform up first (now with authenticationEnabled=false)
./start.sh
docker compose logs -f producer   # PUBLISHED ...
```

Optional verification consumer (the pulsar-client stack is the real consumer):
```bash
docker compose --profile consumer up -d && docker compose logs -f consumer
```

### Configuration (env vars, all optional)

| Var | Default | Meaning |
|---|---|---|
| `TOPIC` | `topic` | Bare topic name; effective topic is `persistent://tenant/namespace/$TOPIC` |
| `PUBLISH_INTERVAL` | `1` | Seconds between messages |
| `TENANT` / `NAMESPACE` | `tenant` / `namespace` | Used by the optional consumer; the producer side's tenant/namespace live in [daprPubSub.yaml](daprPubSub.yaml) and must match |

### Publish manually

```bash
curl -X POST "http://localhost:3500/v1.0/publish/pulsar-pubsub/topic?metadata.rawPayload=true" \
  -H 'Content-Type: application/json' -d '{"text":"hello from curl"}'
```
