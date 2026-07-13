# Motivation

## Problem Statement
COTS applications cannot embed a Pulsar native client: their code is closed,
so there is no way to add an SDK, handle client certificates, or speak the
Pulsar binary protocol. What they do support are standard interfaces — HTTP
and gRPC. Today that leaves them without a path to MaaS, or forces custom
bridge services that someone has to build and maintain for every application.

## Hypothesis
Dapr closes exactly this gap. A Dapr sidecar exposes messaging as plain HTTP
and gRPC APIs on one side and speaks native Pulsar to MaaS on the other,
configured with YAML only. If a deliberately minimal stand-in for a COTS
application — curl to publish, a bare HTTP endpoint to receive — can exchange
messages with MaaS through the sidecar, then any COTS application that can
make an HTTP/gRPC call or receive a webhook can be connected without touching
its code.

## Expected Value
- A supported integration path to MaaS for COTS applications that could not
  connect at all today — no SDK, no code changes, only sidecar configuration.
- One standardized pattern (the Dapr sidecar) instead of per-application
  custom bridges, keeping Pulsar-specific concerns on the platform side.
- Evidence for the operational questions that decide adoption: measured
  throughput (~3K msg/s on 2 cores even with a naive curl producer), rate
  control, and log-based observability on every hop.
- A clear picture of the one gap found: Dapr's built-in Pulsar component
  lacks client-certificate (mTLS) authentication, which a secured MaaS
  requires. That gap is being closed upstream (dapr/components-contrib,
  tlsCertFile / tlsKeyFile), after which the built-in component covers a
  secured MaaS with configuration alone — no custom component to maintain.
