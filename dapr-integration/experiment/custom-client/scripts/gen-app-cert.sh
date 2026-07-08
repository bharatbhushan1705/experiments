#!/usr/bin/env bash
# Generate a self-signed HTTPS identity for the custom-client Java app and package
# it as a PKCS12 keystore (same "produce a keystore.p12" idea the platform uses for
# its Pulsar identities). Runs inside a plain ubuntu container; installs openssl if
# missing. Output goes to $OUT_DIR (default /certs).
set -euo pipefail

log() { printf '[gen-app-cert] %s\n' "$*"; }

if ! command -v openssl >/dev/null 2>&1; then
  log "installing openssl..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends openssl ca-certificates >/dev/null
fi

OUT_DIR="${OUT_DIR:-/certs}"
CN="${APP_CN:-custom-client}"
P12="${OUT_DIR}/app-keystore.p12"
PW="${KEYSTORE_PASSWORD:-changeme}"
DAYS="${DAYS:-365}"

mkdir -p "${OUT_DIR}"

if [[ -f "${P12}" && "${FORCE:-false}" != "true" ]]; then
  log "keystore already exists: ${P12} (set FORCE=true to regenerate)"
  exit 0
fi

log "generating self-signed cert+key for CN=${CN}..."
openssl req -x509 -newkey rsa:2048 -sha256 -days "${DAYS}" -nodes \
  -keyout "${OUT_DIR}/app.key" \
  -out    "${OUT_DIR}/app.crt" \
  -subj   "/CN=${CN}" \
  -addext "subjectAltName=DNS:${CN},DNS:localhost"

log "packaging into PKCS12 keystore ${P12}..."
openssl pkcs12 -export \
  -inkey "${OUT_DIR}/app.key" \
  -in    "${OUT_DIR}/app.crt" \
  -name  "${CN}" \
  -out   "${P12}" \
  -passout "pass:${PW}"

chmod 644 "${P12}"
log "done:"
ls -lh "${P12}" "${OUT_DIR}/app.crt"
