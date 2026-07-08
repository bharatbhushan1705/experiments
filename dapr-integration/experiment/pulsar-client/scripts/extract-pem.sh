#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[extract-pem] %s\n' "$*"
}

err() {
  printf '[extract-pem][ERROR] %s\n' "$*" >&2
}

install_openssl_if_missing() {
  if command -v openssl >/dev/null 2>&1; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "OpenSSL not found. Installing with apt-get..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends openssl ca-certificates
    rm -rf /var/lib/apt/lists/*
  else
    err "OpenSSL is missing and apt-get is not available in this container."
    exit 1
  fi
}

main() {
  install_openssl_if_missing

  local base_path="${VOLUME_PATH:-}"
  local p12_file="${P12_FILE:-keystore.p12}"
  local p12_password="${P12_PASSWORD:-}"

  if [[ -z "$base_path" ]]; then
    err "VOLUME_PATH is required (example: /maas/identities/nginx)."
    exit 1
  fi

  if [[ -z "$p12_password" ]]; then
    err "P12_PASSWORD is required."
    exit 1
  fi

  local p12_path="${base_path}/${p12_file}"
  local privkey_path="${base_path}/privkey.key"
  local fullchain_path="${base_path}/fullchain.pem"
  local cert_path="${base_path}/cert.pem"
  local chain_path="${base_path}/chain.pem"
  local combined_crt_path="${base_path}/combined.pem"

  if [[ ! -f "$p12_path" ]]; then
    err "PKCS#12 file not found: $p12_path"
    exit 1
  fi

  log "Extracting private key from ${p12_path}..."
  openssl pkcs12 \
    -in "$p12_path" \
    -passin "pass:${p12_password}" \
    -nodes \
    -nocerts \
    -out "$privkey_path"

  log "Extracting client certificate to  ${cert_path}..."
  openssl pkcs12 \
    -in "$p12_path" \
    -passin "pass:${p12_password}" \
    -clcerts \
    -nokeys \
    -out "${cert_path}"

  log "Extracting certificate (leaf) to ${fullchain_path}..."
  openssl pkcs12 \
    -in "$p12_path" \
    -passin "pass:${p12_password}" \
    -clcerts \
    -nokeys \
    -out "$fullchain_path"

  log "Extracting CA chain to ${chain_path} (if present)..."
  openssl pkcs12 \
    -in "$p12_path" \
    -passin "pass:${p12_password}" \
    -cacerts \
    -nokeys \
    -chain \
    -out "$chain_path" || true

  if [[ -s "$chain_path" ]]; then
    log "Merging leaf certificate + CA chain into fullchain.pem..."
    cat "$fullchain_path" "$chain_path" > "${fullchain_path}.tmp"
    mv "${fullchain_path}.tmp" "$fullchain_path"
  fi

  # Combined CRT for tools that expect cert+key in one PEM-formatted file.
  cat "$fullchain_path" "$privkey_path" > "$combined_crt_path"

  chmod 600 "$privkey_path" "$combined_crt_path"
  log "Done. Generated:"
  ls -lh "$privkey_path" "$fullchain_path" "$combined_crt_path"
}

main "$@"
