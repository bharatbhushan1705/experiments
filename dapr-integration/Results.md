# Results

## What was verified
We verified both Dapr sidecars, one in produce mode and one in consume mode.
The stand-in COTS application publishes messages over plain HTTP to its
producing sidecar, and the consuming sidecar delivers messages from MaaS back
to the application over plain HTTP. Message flow works in both directions with
no Pulsar-specific code in the application — the sidecars do all the
translation between HTTP and the native Pulsar protocol.

Everything is configuration: one pub/sub Component and one Subscription in
YAML. The whole setup is repeatable with a single startup script that asserts
both flows end to end.

## Measurements
We were able to sustain throughput with a 100% success rate: every message
produced through the sidecar was received by the consumer, in both directions,
on modest resources. Rate control works across the whole range, from a few
messages per minute (paced mode) up to bursts of thousands of messages per
second. Every hop is also observable — publish calls are visible in the
producing sidecar's log, and the consuming application logs a per-message
running total — so message flow can be followed and verified at any point.

## Findings and gaps
Dapr's built-in `pubsub.pulsar` component cannot authenticate with a client
certificate (mTLS), which a secured MaaS requires. Transport-level bridges
cannot work around this, because Pulsar authentication happens at the
application layer, not at the connection layer. As an interim option, Dapr
supports pluggable components: a small external Pulsar component with mTLS
support can be loaded alongside the built-in ones until the gap is closed.

The permanent fix is a contribution to the built-in component in
dapr/components-contrib. Proposal — what needs to be done:
- Add four parameters to the component metadata: `tlsCertFile`, `tlsKeyFile`,
  `tlsTrustCertsFilePath`, and `tlsValidateHostname`.
- Wire them into the Pulsar client: the certificate/key pair as TLS
  authentication, the trust and hostname options as client settings.
- Cover the change with unit tests and a new mTLS scenario in the component's
  certification suite (a broker that enforces client-certificate
  authentication), since a green certification suite is required for merging.

The amount of work is contained: a small change to one component plus tests,
followed by the upstream process — a proposal issue, a pull request, and a
documentation update.

## Conclusion
The hypothesis holds: a COTS application that supports HTTP can produce and
consume MaaS messages through Dapr sidecars with configuration only, at
sustained throughput and with a 100% success rate. The one capability gap is
client-certificate (mTLS) authentication in the built-in Pulsar component; a
pluggable component covers it in the interim, and a contained upstream
contribution would close it permanently.
