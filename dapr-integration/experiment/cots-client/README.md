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

## How the producer command works

Step by step through the shell script in [docker-compose.yaml](docker-compose.yaml):

| Line | What it does |
|---|---|
| `URL="${DAPR_HTTP}/v1.0/publish/${PUBSUB_NAME}/${TOPIC}?metadata.rawPayload=true"` | Builds the Dapr publish URL. `rawPayload=true` stores the body on the topic as-is instead of wrapping it in a CloudEvent. |
| `until curl -fsS ${DAPR_HTTP}/v1.0/healthz; do sleep 2` | Waits until the sidecar is ready (`-f` = fail on HTTP errors, `-s` = quiet, `-S` = still show the error). |
| `[ -n "${RATE}" ]` | `RATE` set → paced mode; unset → falls through to burst mode. |
| `N=${LOG_EVERY}; [ N -lt 10 ] && N=10` | Paced-mode batch size. `--rate` paces transfers *inside* one curl run, so each run needs several urls; below 10 pacing gets inaccurate, so 10 is the floor. |
| `while [ i -lt N ]; do echo "url = \"$URL\""; done > /tmp/urls.cfg` | Writes the same URL N times in curl's config-file syntax — one line per message to send. |
| `curl -fsS --rate ${RATE} -X POST -d "$BODY" --config /tmp/urls.cfg` | One curl run = N POSTs at the exact rate over a single keep-alive connection. |
| `ERR=$(curl ... 2>&1 >/dev/null)` | Captures curl's *errors* into `ERR` while discarding response bodies (order matters: stderr → stdout first, then stdout → /dev/null). |
| `t=$((t+N)); echo "sent $t msgs total"` | Running total, one log line per batch. |
| *burst mode:* `/tmp/urls.cfg` with `BURST` lines | Same trick, but `BURST` (default 1000) urls per curl run. |
| `curl -fsS -Z --parallel-max ${PARALLEL_MAX} --parallel-immediate ...` | `-Z` sends all `BURST` requests concurrently in one curl, over up to `PARALLEL_MAX` keep-alive connections, as fast as they complete — this is what makes burst mode fast. |
| `[ b -eq 1 ] \|\| [ b % LOG_EVERY -eq 0 ]` | Prints the first burst and then every `LOG_EVERY`-th; the line shows cumulative count and average rate since start. |
| `echo "burst $b: FAILED ($(echo "$ERR" \| grep -c .) of ${BURST} ...)"` | On failure: `grep -c .` counts curl's error lines = number of failed requests; `head -1` shows the first error. Failures always print, regardless of `LOG_EVERY`. |

## How the consumer command works

The consumer is a stock `python http.server` — Dapr's consumer sidecar POSTs every
`cots-topic` message to it, so "consuming from Pulsar" is just serving a webhook:

| Line | What it does |
|---|---|
| `log_every = int(os.environ.get('LOG_EVERY', '10'))` | Reads the logging knob from the environment. |
| `count = itertools.count(1)` | Thread-safe running counter of received messages. |
| `def do_POST(self):` | Called once per delivered message. |
| `body = self.rfile.read(int(self.headers.get('Content-Length') or 0))` | Reads the request body — the delivered message. |
| `event = json.loads(body); base64.b64decode(event['data_base64'])` | Dapr delivers the raw Pulsar payload wrapped in a CloudEvent with the bytes in `data_base64`; this unwraps it back to the original text. Falls back to the raw body if it isn't JSON. |
| `if n == 1 or n % log_every == 0: print('#%d' % n, ...)` | Logs message #1 (so you see it working immediately) and then every `LOG_EVERY`-th, prefixed with the running total. |
| `self.send_response(200)` | The ack: any 2xx tells the sidecar the message is processed. A non-2xx (or crash) makes Dapr redeliver it. |
| `def do_GET` → 200 | Answers the sidecar's startup probes. |
| `def log_message: pass` | Silences http.server's built-in one-line-per-request logging (the counter above replaces it). |
| `ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()` | Serves on the port the sidecar's `--app-port 8080` points at; threaded so concurrent deliveries don't queue. |

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
RATE=1/h ./start.sh      # one message per hour
RATE=500/s ./start.sh    # smooth 500 msg/s
./start.sh               # unset RATE = back to burst mode
```

Always give a unit (`/s`, `/m`, `/h`, `/d`) — a bare number like `RATE=1` means
per **hour** in curl. In paced mode messages go out in batches of at least 10
urls per curl invocation (pacing happens inside one invocation), so `LOG_EVERY`
below 10 is raised to 10 there.

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
