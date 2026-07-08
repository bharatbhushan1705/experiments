#!/usr/bin/env bash
# Verification ONLY. Generates a throwaway PKI that mimics the real platform closely
# enough to exercise the pipeline:
#   * a CA
#   * a Pulsar SERVER cert (SAN: DNS:${SERVER_DNS} + a SPIFFE URI, like the platform's)
#   * a CLIENT cert with CN=${CLIENT_ROLE} (the Pulsar auth role), used by the
#     pluggable component and the consumer
# Output -> $OUT_DIR (default /certs/pulsar).
set -euo pipefail
log() { printf '[gen-test-certs] %s\n' "$*"; }

if ! command -v openssl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null && apt-get install -y --no-install-recommends openssl >/dev/null
fi

OUT="${OUT_DIR:-/certs/pulsar}"
SERVER_DNS="${SERVER_DNS:-pulsar}"
SERVER_URI="${SERVER_URI:-spiffe://test/pulsar-proxy}"
CLIENT_ROLE="${CLIENT_ROLE:-admin}"
DAYS=3650
mkdir -p "${OUT}"
cd "${OUT}"

if [[ -f ca.pem && -f server.crt && -f client.crt ]]; then
  log "certs already present in ${OUT}"; exit 0
fi

log "1) CA"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days ${DAYS} \
  -subj "/CN=test-ca" >/dev/null 2>&1

log "2) Pulsar server cert (SAN = DNS:${SERVER_DNS},URI:${SERVER_URI})"
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=pulsar-proxy" >/dev/null 2>&1
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days ${DAYS} \
  -out server.crt \
  -extfile <(printf "subjectAltName=DNS:%s,URI:%s\nextendedKeyUsage=serverAuth\n" "${SERVER_DNS}" "${SERVER_URI}") >/dev/null 2>&1

log "3) Client cert (CN=${CLIENT_ROLE}, PKCS#8 key)"
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
  -subj "/CN=${CLIENT_ROLE}" >/dev/null 2>&1
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days ${DAYS} \
  -out client.crt \
  -extfile <(printf "extendedKeyUsage=clientAuth\n") >/dev/null 2>&1

# Pulsar clients want a PKCS#8 key; openssl -newkey already emits PKCS#8.
chmod 644 ca.pem server.crt client.crt
chmod 640 ca.key server.key client.key
rm -f server.csr client.csr
log "done. files in ${OUT}:"
ls -1 "${OUT}"
