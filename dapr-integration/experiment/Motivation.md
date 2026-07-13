# Motivation

## Problem Statement
Every application that wants to use the Pulsar messaging platform today has to
become a Pulsar client: pick an SDK for its language, handle client
certificates and TLS, understand tenants/namespaces/topics, and maintain all
of that as the platform evolves. For COTS and legacy applications that only
speak HTTP, this is a blocker; for everyone else it is repeated integration
effort in every team.

## Hypothesis
Dapr can remove that burden with its built-in Pulsar support: applications
talk plain HTTP to a Dapr sidecar (POST to publish, a webhook to consume),
and the sidecar — configured with YAML only, no custom code — handles the
Pulsar protocol, connection security, and subscriptions. If a deliberately
minimal client (curl and a tiny HTTP server) can publish and consume through
Dapr against the platform, then any application that can make an HTTP call
can be onboarded.

## Expected Value
- One standardized integration path to the messaging platform instead of a
  per-team, per-language Pulsar client: apps stay broker-agnostic and need
  zero Pulsar-specific code.
- Lower onboarding cost, especially for COTS/legacy applications that cannot
  embed an SDK at all.
- Evidence for the operational questions that decide adoption: measured
  throughput (~3K msg/s on 2 cores with a naive curl producer), rate
  control, and log-based observability on every hop.
- A clear picture of the one gap found: the built-in component could not do
  client-certificate (mTLS) authentication, which secured platforms require.
  That gap is being closed upstream (dapr/components-contrib, tlsCertFile /
  tlsKeyFile), after which the built-in option covers the secured platform
  with configuration alone — no custom component to maintain.
