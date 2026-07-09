# Dapr → mTLS Apache Pulsar (pluggable component experiment)

**Question:** can an app publish through a **Dapr sidecar** to an **mTLS-secured Apache
Pulsar**, with the client certificate configured in Dapr?
**Answer: yes — but only with a *pluggable* Pulsar component.** Verified end to end.

```
 producer (curl loop, 1 msg/s)
    │  POST http://daprd:3500/v1.0/publish/pulsar-pubsub/<url-encoded full topic>
    ▼
 daprd 1.15.4  ──loads──►  pubsub.pulsar-pluggable   (daprPubSub.yaml)
    │  gRPC over unix socket /tmp/dapr-components-sockets/pulsar-pluggable.sock
    ▼
 pulsar-pluggable  (Go; pulsar.NewAuthenticationTLS(cert,key) → auth_method=tls)
    │  pulsar+ssl://maas-proxy:6651   ← REAL per-client mTLS auth, cert from Dapr config
    ▼
 platform Pulsar (mTLS)  ──►  (optional) verification consumer, profile-gated
```

Topic convention is the same as the pulsar-client stack:
`persistent://tenant/namespace/topic` (tenant/namespace/topic and the publish interval
are configurable — see below).

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
| Transport bridge (ghostunnel/haproxy), explored and discarded | ❌ (cert in bridge) | ❌ needs broker `anonymousUserRole`¹ | ✅ |
| **Pluggable component (this dir)** | ✅ | ✅ | ✅ (build one Dockerfile) |

¹ A transport bridge presents the cert at the TLS layer, but Pulsar authentication is an
*app-protocol* step (`auth_method_name=tls` in the CONNECT frame). A tunnel can't inject
it, so the broker sees `principal=null` unless it accepts anonymous connections.

## Files

| Path | What |
|---|---|
| [daprPubSub.yaml](daprPubSub.yaml) | The component: `pubsub.pulsar-pluggable`, cert paths, `serviceUrl`, tenant/namespace. |
| [pluggable-component/](pluggable-component/) | The Go component (`main.go`) + `Dockerfile`. mTLS via `NewAuthenticationTLS`. Deps vendored → builds offline. |
| [docker-compose.yaml](docker-compose.yaml) | cert utilities + pluggable + daprd + curl producer (+ optional profile-gated consumer), on the platform network. |
| [start.sh](start.sh) | Checks identities → builds component → `docker compose up`. |
| (cert extraction) | Reuses [../pulsar-client/scripts/extract-pem.sh](../pulsar-client/scripts/extract-pem.sh) via the same openssl utility containers as pulsar-client — extracts `cert.pem`/`privkey.key`/`fullchain.pem` in-place in `../.ignore.identities/`. |
| [verify-local/](verify-local/) | Self-contained proof against a stock mTLS Pulsar (no platform needed). |

## Run it — self-contained proof (recommended first)

No platform needed; stands up a stock Pulsar with mandatory client-cert auth and drives
the whole pipeline:

```bash
cd verify-local && ./verify.sh
```
Expected tail:
```
Component loaded: pulsar-pubsub (pubsub.pulsar-pluggable/v1)
pulsar-pluggable: Connection is ready ... pulsar+ssl://pulsar:6651
producer: PUBLISHED {"id":1,...}     →     consumer: got message {"id":1,...}
PASS: N messages went producer(curl) -> Dapr -> pluggable(mTLS auth) -> Pulsar -> consumer
```
Clean up: `docker compose down -v`.

## Run it — against the platform

```bash
../platform/start.sh      # platform up first (generates ../.ignore.identities)
./start.sh
docker compose logs -f producer   # PUBLISHED ...
```

The consumer is **not started by default** — the pulsar-client stack is the real
consumer. To watch the experiment topic without touching pulsar-client, enable the
optional profile-gated one:
```bash
docker compose --profile consumer up -d
docker compose logs -f consumer   # got message ...
```

### Configuration (env vars, all optional)

| Var | Default | Meaning |
|---|---|---|
| `TENANT` / `NAMESPACE` / `TOPIC` | `tenant` / `namespace` / `topic` | Full topic = `persistent://$TENANT/$NAMESPACE/$TOPIC` (producer and the optional consumer both follow it) |
| `PUBLISH_INTERVAL` | `1` | Seconds between messages |
| `P12_PASSWORD` | `changeme` | Platform keystore password |
| `PLUGGABLE_IMAGE` | *(build locally)* | Prebuilt pluggable-component image to pull instead of building |

Example: `TOPIC=orders PUBLISH_INTERVAL=5 ./start.sh`

### Publish manually

daprd's HTTP port is published on the host, so you can also publish ad hoc. The topic
must be URL-encoded (daprd's router collapses the `//` in `persistent://`):

```bash
curl -X POST "http://localhost:3500/v1.0/publish/pulsar-pubsub/persistent%3A%2F%2Ftenant%2Fnamespace%2Ftopic?metadata.rawPayload=true" \
  -H 'Content-Type: application/json' -d '{"text":"hello from curl"}'
```
(Unencoded topics still work — the component repairs the collapsed prefix — but
encoding is the correct form.)

## Troubleshooting the build

- **`net/http: TLS handshake timeout` on `go mod download`** — a firewall is blocking the
  Go module proxy. Deps are vendored so this shouldn't happen; if you removed `vendor/`,
  either restore it or set `GOPROXY` to your internal Artifactory.
- **`inconsistent vendoring ... not marked as explicit in vendor/modules.txt`** — your copy
  of `vendor/modules.txt` is out of sync (a partial file copy, or Windows CRLF conversion).
  Fix: get a clean copy via `git clone`/`git pull` (the included `.gitattributes` keeps
  `vendor/` LF-only), **or** skip the build with `PLUGGABLE_IMAGE=<your image>`, **or**
  regenerate where a Go proxy is reachable: `cd pluggable-component && rm -rf vendor && go mod vendor`.

## Notes / assumptions

- The component's Go deps are **vendored** and the Dockerfile builds with `GOPROXY=off`,
  so the image builds **fully offline** (works behind a corporate firewall).
- `daprd` runs as root so it can reach the socket the component creates on the shared
  volume (default folder `/tmp/dapr-components-sockets`).
- `tlsEnableHostnameVerification=false` + `tlsAllowInsecureConnection=true` in
  [daprPubSub.yaml](daprPubSub.yaml) match the platform's `client.conf` posture (SPIFFE
  certs without DNS SANs). Tighten if your proxy cert has a matching DNS SAN.
- To swap in a prebuilt (e.g. ACR) pluggable image: `PLUGGABLE_IMAGE=<image> ./start.sh`.
  `daprPubSub.yaml` stays the same; the image must register its socket as
  `pulsar-pluggable.sock`.
