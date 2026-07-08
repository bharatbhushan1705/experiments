# Dapr → mTLS Apache Pulsar (custom-client experiment)

**Question:** can a custom app publish/consume through a **Dapr sidecar** to an
**mTLS-secured Apache Pulsar**, with the client certificate configured in Dapr?
**Answer: yes — but only with a *pluggable* Pulsar component.** This directory holds
the Dapr side; the Java app lives in [../custom-client/](../custom-client/).

```
 custom-client (Java, HTTPS self-signed)        ../custom-client/app/CustomClient.java
    │  POST http://daprd:3500/v1.0/publish/pulsar-pubsub/custom-client-topic
    ▼
 daprd 1.15.4  ──loads──►  pubsub.pulsar-pluggable   (daprPubSub.yaml)
    │  gRPC over unix socket /tmp/dapr-components-sockets/pulsar-pluggable.sock
    ▼
 pulsar-pluggable  (Go; pulsar.NewAuthenticationTLS(cert,key) → auth_method=tls)
    │  pulsar+ssl://proxy:6651   ← REAL per-client mTLS auth, cert from Dapr config
    ▼
 platform Pulsar (mTLS)  ──►  consumer reads the topic back over mTLS
```

## Why a pluggable component (not stock daprd)

The **built-in** `pubsub.pulsar` inside `daprd` has **no client-certificate fields** —
only `enableTLS`, `token` (JWT) and `oauth2*`. Verified against `metadata.yaml` and the
Dapr docs. So "put the cert in Dapr config" is impossible with the built-in component.

The **pluggable** component *does* expose `tlsCertFile`/`tlsKeyFile` (see
[daprPubSub.yaml](daprPubSub.yaml)) because it's a separate process that runs a real
Pulsar client. That is the only way to get client-cert mTLS **auth** through Dapr:

| Approach | Cert in Dapr config? | Real mTLS auth? | Public images only? |
|---|---|---|---|
| Built-in `pubsub.pulsar` | ❌ no such field | ❌ | ✅ |
| Transport bridge (ghostunnel/haproxy) — see [../custom-client/test-local/](../custom-client/test-local/) | ❌ (cert in bridge) | ❌ needs broker `anonymousUserRole`¹ | ✅ |
| **Pluggable component (this dir)** | ✅ | ✅ | ✅ (build one Dockerfile) |

¹ A transport bridge presents the cert at the TLS layer, but Pulsar authentication is an
*app-protocol* step (`auth_method_name=tls` in the CONNECT frame). A tunnel can't inject
it, so the broker sees `principal=null` unless it accepts anonymous connections.

## Files

| Path | What |
|---|---|
| [daprPubSub.yaml](daprPubSub.yaml) | The component: `pubsub.pulsar-pluggable`, cert paths, `serviceUrl`, tenant/namespace. |
| [pluggable-component/](pluggable-component/) | The Go component (`main.go`) + `Dockerfile`. mTLS via `NewAuthenticationTLS`. |
| [docker-compose.yaml](docker-compose.yaml) | daprd + pluggable + custom-client + consumer, on the platform network. |
| [scripts/prep-certs.sh](scripts/prep-certs.sh) | Extracts `client.crt`/`client.key`/`ca.pem` from the platform identities. |
| [start.sh](start.sh) | Prep certs → build component → `docker compose up`. |
| [verify-local/](verify-local/) | Self-contained proof against a stock mTLS Pulsar (no platform needed). |

## Run it — self-contained proof (recommended first)

No platform, no private image, no `anonymousUserRole`. Stands up a stock Pulsar with
mandatory client-cert auth and drives the whole pipeline:

```bash
cd verify-local && ./verify.sh
```
Expected tail:
```
Component loaded: pulsar-pubsub (pubsub.pulsar-pluggable/v1)
pulsar-pluggable: Connection is ready ... pulsar+ssl://pulsar:6651
custom-client: PUBLISHED {"id":1,...}     →     consumer: got message {"id":1,...}
PASS: N messages went custom-client -> Dapr -> pluggable(mTLS auth) -> Pulsar -> consumer
```
This was verified end-to-end (real per-client cert auth, `authenticationEnabled=true`,
no anonymous role). Clean up: `docker compose down -v`.

## Run it — against the platform

```bash
../platform/start.sh      # brings up the mTLS Pulsar cluster (needs the ING images)
./start.sh                # extracts certs from ../.ignore.identities, builds, and starts
docker compose logs -f custom-client   # PUBLISHED ...
docker compose logs -f consumer        # got message ...
```

## Swap in your own (ING) pluggable image

The component here is an **open-source stand-in** with the same component type and the
same metadata contract as your private `pulsar-pluggable`. To use yours, replace the
`build:`/`image:` of the `pulsar-pluggable` service in [docker-compose.yaml](docker-compose.yaml):

```yaml
  pulsar-pluggable:
    image: p10530maasacr.azurecr.io/pulsar-pluggable:<tag>   # your ACR build
    volumes:
      - dapr-sockets:/tmp/dapr-components-sockets
      - ./certs:/certs:ro
```
`daprPubSub.yaml` stays exactly the same — the cert is still configured in Dapr.

## Notes / assumptions

- Java app runs from source via **JEP 330** (`java CustomClient.java`) on `eclipse-temurin:21-jdk` — no Dockerfile, no Maven.
- `daprd` runs as root so it can reach the socket the component creates on the shared volume (default folder `/tmp/dapr-components-sockets`).
- `tlsEnableHostnameVerification=false` + `tlsAllowInsecureConnection=true` in the component match the platform's `client.conf` posture (SPIFFE certs without DNS SANs). Tighten if your proxy cert has a matching DNS SAN.
- The platform itself needs the ING images to generate SPIFFE identities; it can't run with stock `apachepulsar/pulsar` (which has no `MODE`/identity entrypoint). That's why verification uses a stock standalone with its own throwaway PKI.
