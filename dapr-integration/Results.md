# Results

## What was verified
- Bidirectional message flow between a minimal COTS stand-in (curl producer,
  bare HTTP endpoint consumer) and Pulsar, entirely through Dapr sidecars:
  publish via `POST` to the sidecar, consume via webhook delivery from the
  sidecar. No Pulsar-specific code in the application containers.
- Everything is configuration: one Dapr Component (connection, tenant/
  namespace) and one Subscription (topic → route) in YAML.
- Repeatable end-to-end check: `experiment/start-integration.sh` starts all
  stacks and asserts both flows.

## Measurements
- Throughput: ~3,100 msg/s produced / ~3,700 msg/s received sustained on
  2 cores (p95 18 ms), even with a naive curl-based producer. Sustained
  higher rates need a pooled client/SDK on the producing side.
- Rate control works down to very low volumes (paced mode via curl `--rate`);
  producer and consumer knobs are documented in `experiment/README.md`.
- Observability: every hop is log-visible — publish calls on the producer
  sidecar (`--enable-api-logging`), per-message running totals in the
  consumer. Deliveries are outbound calls from the consumer sidecar, so they
  appear in the receiving app's log, not the sidecar's.

## Findings and gaps
- Dapr's built-in `pubsub.pulsar` component cannot authenticate with a client
  certificate (mTLS), which a secured MaaS requires. Transport-level bridges
  cannot work around this: Pulsar authentication is application-layer.
- Interim solution verified end-to-end: a Go pluggable component
  (`pulsar-client-go` + `NewAuthenticationTLS`) that daprd loads alongside
  built-in components (frozen on branch `experiment/dapr-pulsar-mtls`).
- Permanent fix in progress upstream: `tlsCertFile`/`tlsKeyFile` (plus
  `tlsTrustCertsFilePath`/`tlsValidateHostname`) contributed to
  dapr/components-contrib, including a new mTLS certification scenario. The
  full upstream certification suite passes with the change; once merged, the
  built-in component covers a secured MaaS with configuration alone.

## Conclusion
The hypothesis holds: a COTS application that supports HTTP can exchange
messages with MaaS through a Dapr sidecar with zero application code changes.
The one capability gap found (mTLS authentication) has a verified interim
solution and an upstream fix underway.
