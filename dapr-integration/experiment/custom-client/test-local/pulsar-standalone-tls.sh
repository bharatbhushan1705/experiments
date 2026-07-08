#!/usr/bin/env bash
# Verification ONLY: start a stock apachepulsar/pulsar standalone with TLS + mandatory
# client-certificate (mTLS) auth, using the throwaway certs from gen-test-certs.sh.
# This stands in for the real mTLS-secured platform so we can exercise the pipeline
# end to end with public images.
set -euo pipefail
CONF=/pulsar/conf/standalone.conf
CERTS=/certs/pulsar

echo "[pulsar-tls] waiting for certs in ${CERTS}..."
for _ in $(seq 1 60); do
  [[ -f ${CERTS}/server.crt && -f ${CERTS}/server.key && -f ${CERTS}/ca.pem ]] && break
  sleep 2
done
[[ -f ${CERTS}/server.crt ]] || { echo "[pulsar-tls] certs never appeared"; exit 1; }

cat >> "${CONF}" <<EOF

### injected by pulsar-standalone-tls.sh (experiment mTLS) ###
brokerServicePortTls=6651
webServicePortTls=8443
tlsCertificateFilePath=${CERTS}/server.crt
tlsKeyFilePath=${CERTS}/server.key
tlsTrustCertsFilePath=${CERTS}/ca.pem
tlsRequireTrustedClientCertOnConnect=true
authenticationEnabled=true
authenticationProviders=org.apache.pulsar.broker.authentication.AuthenticationProviderTls
authorizationEnabled=false
superUserRoles=admin
# the broker's own internal client must present a trusted cert over TLS
brokerClientTlsEnabled=true
brokerClientTrustCertsFilePath=${CERTS}/ca.pem
brokerClientAuthenticationPlugin=org.apache.pulsar.client.impl.auth.AuthenticationTls
brokerClientAuthenticationParameters=tlsCertFile:${CERTS}/client.crt,tlsKeyFile:${CERTS}/client.key
EOF

# Diagnostic ONLY: if ANONYMOUS_ROLE is set, accept connections that present a trusted
# client cert at the TLS layer but do NOT speak Pulsar's app-layer auth handshake
# (i.e. the transport-only bridge case). This is what a terminating bridge would need,
# and it is a BROKER-SIDE change the real platform does not have.
if [[ -n "${ANONYMOUS_ROLE:-}" ]]; then
  echo "anonymousUserRole=${ANONYMOUS_ROLE}" >> "${CONF}"
  echo "[pulsar-tls] (diagnostic) anonymousUserRole=${ANONYMOUS_ROLE}"
fi

echo "[pulsar-tls] starting standalone (TLS 6651 / 8443, mTLS required)..."
exec bin/pulsar standalone -nss -nfw
