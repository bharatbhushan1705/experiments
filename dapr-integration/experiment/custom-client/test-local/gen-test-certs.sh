#!/usr/bin/env bash
# Self-contained verification ONLY. Generates a throwaway PKI that mimics the real
# platform closely enough to exercise the exact Dapr -> bridge -> mTLS-Pulsar ->
# consumer pipeline:
#   * a CA
#   * a Pulsar SERVER cert. By default the SAN includes BOTH DNS:${SERVER_DNS} and a
#     SPIFFE URI, so the ghostunnel bridge (which enforces hostname verification) can
#     connect via --override-server-name ${SERVER_DNS}.
#     Set URI_ONLY=true to emit a SPIFFE-URI-ONLY cert (no DNS) that reproduces the
#     platform's SPIFFE certs; ghostunnel then CANNOT verify it and the HAProxy bridge
#     (skip-hostname) is required. This lets us test both bridges.
#   * a CLIENT cert with CN=${CLIENT_ROLE} (the Pulsar auth role), used by the bridge
#     and the consumer.
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
URI_ONLY="${URI_ONLY:-false}"
DAYS=3650
mkdir -p "${OUT}"
cd "${OUT}"

if [[ -f ca.pem && -f server.crt && -f client.crt && "${FORCE:-false}" != "true" ]]; then
  log "certs already present in ${OUT} (set FORCE=true to regenerate)"; exit 0
fi

log "1) CA"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days ${DAYS} \
  -subj "/CN=test-ca" >/dev/null 2>&1

if [[ "${URI_ONLY}" == "true" ]]; then
  SAN="URI:${SERVER_URI}"
  log "2) Pulsar server cert (SAN = ${SAN}  -- URI-only; ghostunnel will NOT verify this)"
else
  SAN="DNS:${SERVER_DNS},URI:${SERVER_URI}"
  log "2) Pulsar server cert (SAN = ${SAN})"
fi
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=pulsar-proxy" >/dev/null 2>&1
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days ${DAYS} \
  -out server.crt \
  -extfile <(printf "subjectAltName=%s\nextendedKeyUsage=serverAuth\n" "${SAN}") >/dev/null 2>&1

log "3) Client cert (CN=${CLIENT_ROLE}, PKCS#8 key)"
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
  -subj "/CN=${CLIENT_ROLE}" >/dev/null 2>&1
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days ${DAYS} \
  -out client.crt \
  -extfile <(printf "extendedKeyUsage=clientAuth\n") >/dev/null 2>&1

# HAProxy's `crt` server directive wants cert+key in ONE PEM file.
cat client.crt client.key > client-combined.pem

# Pulsar's Java client wants a PKCS#8 key; openssl -newkey already emits PKCS#8.
chmod 644 ca.pem server.crt client.crt client-combined.pem
chmod 640 ca.key server.key client.key
rm -f server.csr client.csr
log "done. files in ${OUT}:"
ls -1 "${OUT}"
