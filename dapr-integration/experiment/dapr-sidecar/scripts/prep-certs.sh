#!/usr/bin/env bash
# Populate ./certs for the pluggable component + consumer from the platform's generated
# identities. Extracts the client identity (admin) and CA (trust) from the PKCS12
# keystores the platform 'identity' service produces, as PEM:
#   client.crt  (leaf cert)   client.key  (PKCS#8 key)   ca.pem  (trust CA)
#
# Runs inside an ubuntu container (installs openssl if missing). Invoked by start.sh,
# but you can run it standalone:
#   docker run --rm -e P12_PASSWORD=changeme \
#     -v "$PWD/../.ignore.identities:/identities:ro" -v "$PWD/certs:/out" \
#     -v "$PWD/scripts/prep-certs.sh:/prep.sh:ro" ubuntu:latest bash /prep.sh
set -euo pipefail
log() { printf '[prep-certs] %s\n' "$*"; }

if ! command -v openssl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null && apt-get install -y --no-install-recommends openssl >/dev/null
fi

IDENT="${IDENTITIES_DIR:-/identities}"
OUT="${OUT_DIR:-/out}"
PW="${P12_PASSWORD:-changeme}"
CLIENT_ID="${CLIENT_IDENTITY:-admin}"   # which platform identity Dapr authenticates as
mkdir -p "${OUT}"

KS="${IDENT}/${CLIENT_ID}/keystore.p12"
TS="${IDENT}/trust/truststore.p12"
[[ -f "${KS}" ]] || { log "ERROR: client keystore not found: ${KS} (is the platform up?)"; exit 1; }
[[ -f "${TS}" ]] || { log "ERROR: truststore not found: ${TS}"; exit 1; }

log "extracting client leaf cert -> ${OUT}/client.crt"
openssl pkcs12 -in "${KS}" -passin "pass:${PW}" -nokeys -clcerts -out "${OUT}/client.crt"

log "extracting client key (PKCS#8) -> ${OUT}/client.key"
openssl pkcs12 -in "${KS}" -passin "pass:${PW}" -nodes -nocerts \
  | openssl pkcs8 -topk8 -nocrypt -out "${OUT}/client.key"

log "extracting CA chain -> ${OUT}/ca.pem"
openssl pkcs12 -in "${TS}" -passin "pass:${PW}" -nokeys -cacerts -out "${OUT}/ca.pem"

chmod 644 "${OUT}/client.crt" "${OUT}/ca.pem"
chmod 640 "${OUT}/client.key"
log "done:"
ls -lh "${OUT}/client.crt" "${OUT}/client.key" "${OUT}/ca.pem"
