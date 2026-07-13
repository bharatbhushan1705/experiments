# How To Run

## Prerequisites
- Docker
- Docker Compose (the `docker compose` plugin)
- Bash shell (macOS, Linux, or Windows with WSL2)

## Setup
Ensure that your Docker daemon is running.

No extra local dependencies are required from this document's context, because startup is orchestrated by the experiment scripts.

## Starting the Environment

### Step 1: Navigate to the Experiment Directory
From the root of the project, navigate to the experiment directory:

```bash
cd dapr-integration/experiment
```

### Step 2: Start the Environment
To start the full integration flow, run:

```bash
./start-integration.sh
```

This startup script initializes components in sequence and performs end-to-end assertions on both flows:
1. **Platform** (Pulsar stack)
   - Starts Zookeeper, BookKeeper, Broker, Proxy, and metadata initialization
   - Verifies proxy reachability on port `6650`
   - Verifies namespace creation (`tenant/namespace` by default)

2. **Pulsar client** (consumer + producer)
   - Starts a consumer (`maas-consumer`) that reads from `persistent://tenant/namespace/topic`
   - Starts a producer (`maas-producer`) that publishes to `cots-topic`

3. **COTS client** (producer + consumer)
   - Starts an HTTP producer (`cots-producer`) that publishes through Dapr's publish API
   - Starts an HTTP consumer (`cots-consumer`) that receives `cots-topic` messages delivered by Dapr

4. **Dapr sidecar** (two sidecars)
   - Starts `daprd-producer` (publish API) and `daprd-consumer` (subscription delivery)
   - Waits for `Component loaded: pulsar-pubsub` in both sidecars' logs
   - Waits until at least one message is observed by each consumer

If successful, the script ends with two `PASS` lines confirming message flow in both directions:
`cots-client -> daprd-producer -> topic -> pulsar-client` and
`pulsar-client -> cots-topic -> daprd-consumer -> cots-client`.

### Step 3: Verify the Environment is Running
After startup completes:

```bash
docker ps
```

You should see containers such as:
- `pulsar-proxy` (plus `pulsar-broker`, `pulsar-bookkeeper`, `pulsar-zookeeper`)
- `daprd-producer` and `daprd-consumer`
- `cots-producer` and `cots-consumer`
- `maas-producer` and `maas-consumer`

## What is going on in the environment?

There are four parts in this integration:
- platform
- pulsar-client
- dapr-sidecar
- cots-client

### Platform
The platform is a Pulsar deployment where authentication is disabled for this branch scenario. It includes:
- `zookeeper`
- `bookkeeper`
- `broker`
- `proxy`
- `metadata-init`

Published ports from the proxy:
1. `6650` -> Pulsar protocol endpoint
2. `8080` -> Pulsar admin/web endpoint

### Dapr Sidecar
There are two sidecars, one per direction:
1. `daprd-producer` exposes `3500` -> Dapr HTTP API (`/v1.0/publish/...`, `/v1.0/healthz`)
2. `daprd-consumer` subscribes to `cots-topic` and POSTs each message to `cots-consumer` on route `/messages`

Both load the Pulsar component and the subscription from:
- `dapr-integration/experiment/dapr-sidecar/conf/daprProducerPubSub.yaml` (the pub/sub Component)
- `dapr-integration/experiment/dapr-sidecar/conf/daprConsumerPubSub.yaml` (the Subscription)

### COTS Client
The COTS client is the stand-in for a COTS application and has two containers:
- `cots-producer`, a curl-based producer that:
  - Calls `http://daprd-producer:3500/v1.0/publish/pulsar-pubsub/<topic>`
  - Sends bursts of messages in parallel connections (or paced mode via `RATE`)
  - Defaults to topic `topic`
- `cots-consumer`, a bare HTTP server that receives `cots-topic` messages from `daprd-consumer` and logs a running total

### Pulsar Client
The Pulsar client is the stand-in for a MaaS-side application and has two containers:
- `maas-consumer` continuously consumes from `persistent://tenant/namespace/topic`
- `maas-producer` continuously publishes to `persistent://tenant/namespace/cots-topic` (rate set by `PRODUCE_RATE`, default 10 msg/s)

## Experiments

### Check Dapr Health

```bash
curl -fsS http://localhost:3500/v1.0/healthz
```

A healthy sidecar returns an `OK` response.

### Check Pulsar Component Loaded in Dapr

```bash
cd dapr-sidecar
docker compose logs | grep "Component loaded: pulsar-pubsub"
```

Both `daprd-producer` and `daprd-consumer` should show the line.

### Check End-to-End Message Flow
Use consumer logs to confirm both directions:

```bash
docker logs maas-consumer 2>&1 | grep "Throughput received" | tail -n 5
docker logs cots-consumer --tail=5
```

The `cots-consumer` lines look like `#<total> HH:MM:SS /messages <payload>`; the total should keep increasing.

### Observe Behavior During Platform Failure (Optional)
You can stop one core platform dependency (for example Zookeeper) and observe producer/consumer behavior:

```bash
docker stop pulsar-zookeeper
```

Then monitor:

```bash
docker logs cots-producer --tail=30
docker logs maas-consumer --tail=30
docker logs daprd-producer --tail=30
```

## Stopping and Cleaning Up the Environment

### Standard Cleanup
From `dapr-integration/experiment`:

```bash
./cleanup-integration.sh
```

This stops all components in reverse order:
1. cots-client
2. dapr-sidecar
3. pulsar-client
4. platform

It also deletes the durable `cots-consumer` subscription on `cots-topic`, so no backlog collects while the clients are stopped.

### Client-Only Cleanup
To stop only clients and keep the platform running:

```bash
./cleanup-integration.sh clients
```

## Monitoring the Experiment

During runtime, useful commands include:

- **Platform logs**
```bash
cd platform
docker compose logs -f
```

- **Dapr sidecar logs**
```bash
cd dapr-sidecar
docker compose logs -f daprd-producer daprd-consumer
```

- **COTS producer logs**
```bash
cd cots-client
docker compose logs -f producer
```

- **Consumer logs**
```bash
docker logs -f cots-consumer
docker logs -f maas-consumer
```

## Expected Behavior

### Healthy State
- Dapr health endpoint responds successfully
- Both sidecars load the `pulsar-pubsub` component
- Producers publish continuously in both directions
- `maas-consumer` shows increasing `Throughput received`, `cots-consumer` shows an increasing `#<total>`

### Degraded/Unhealthy State (after stopping core platform service)
- Producer logs may show failed publish bursts
- Consumer throughput can stop increasing
- Dapr stays reachable on `3500`, but publish operations depend on backend availability
