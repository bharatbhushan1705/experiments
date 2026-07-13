# Motivation

## Problem Statement
COTS applications cannot embed a Pulsar native client: their code is closed,
so there is no way to add an SDK, handle client certificates, or speak the
Pulsar binary protocol. What they do support are standard interfaces — HTTP
and gRPC. Today that leaves them without a path to MaaS, or forces custom
bridge services that someone has to build and maintain for every application.

## Hypothesis
Dapr closes exactly this gap. A Dapr sidecar exposes messaging as plain HTTP
and gRPC APIs toward the application and speaks native Pulsar toward MaaS,
configured with YAML only. If a minimal stand-in for a COTS application can
exchange messages with MaaS through the sidecar, then any COTS application
that supports HTTP/gRPC can be connected without touching its code.

## Expected Value
- An integration path to MaaS for COTS applications that have none today —
  no SDK, no code changes, only sidecar configuration.
- One standardized pattern (the Dapr sidecar) instead of per-application
  custom bridges, keeping Pulsar-specific concerns on the platform side.

Findings and measurements are recorded in [Results.md](../Results.md).
