#!/usr/bin/env bash
# Verification ONLY: start a stock apachepulsar/pulsar standalone with a TLS listener
# (self-signed server cert from gen-test-certs.sh) and authentication DISABLED —
# mirroring the platform's no-auth posture. Clients connect over pulsar+ssl without
# verifying the cert and without authenticating.
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

### injected by pulsar-standalone-tls.sh (experiment TLS transport, NO auth) ###
brokerServicePortTls=6651
webServicePortTls=8443
tlsCertificateFilePath=${CERTS}/server.crt
tlsKeyFilePath=${CERTS}/server.key
tlsTrustCertsFilePath=${CERTS}/ca.pem
tlsRequireTrustedClientCertOnConnect=false
authenticationEnabled=false
authorizationEnabled=false
EOF

echo "[pulsar-tls] starting standalone (TLS 6651 / 8443, no auth)..."
exec bin/pulsar standalone -nss -nfw
