#!/usr/bin/env bash
# Verification ONLY: start a stock apachepulsar/pulsar standalone with TLS + mandatory
# client-certificate (mTLS) auth, using the throwaway certs from gen-test-certs.sh.
# Stands in for the real mTLS-secured platform so the pipeline can be exercised end to
# end with public images. Authentication is ENABLED and there is NO anonymous role —
# the client cert must authenticate as a real role.
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

echo "[pulsar-tls] starting standalone (TLS 6651 / 8443, mTLS required)..."
exec bin/pulsar standalone -nss -nfw
