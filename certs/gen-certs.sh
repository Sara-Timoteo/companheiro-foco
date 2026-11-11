#!/usr/bin/env bash
# Generates a private CA plus server and client certificates for mutual TLS.
# Output goes to certs/out/ (git-ignored). Use --force to regenerate.
set -euo pipefail
cd "$(dirname "$0")"

OUT=out
DAYS_CA=365
DAYS_LEAF=90
CLIENTS=(sensor dashboard)

if [[ -d "$OUT" && "${1:-}" != "--force" ]]; then
  echo "certs/out already exists. Run with --force to regenerate."; exit 0
fi
rm -rf "$OUT"; umask 077; mkdir -p "$OUT"

newkey() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }

sign() { # name, common name, extensions
  local name=$1 cn=$2 ext=$3
  newkey "$OUT/$name.key"
  openssl req -new -key "$OUT/$name.key" -subj "/O=Focus Companion/CN=$cn" -out "$OUT/$name.csr"
  openssl x509 -req -in "$OUT/$name.csr" -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" \
    -CAcreateserial -sha256 -days "$DAYS_LEAF" -extfile <(printf '%s\n' "$ext") \
    -out "$OUT/$name.crt" 2>/dev/null
  rm "$OUT/$name.csr"
}

# 1. Private certificate authority (its key never leaves this folder)
newkey "$OUT/ca.key"
openssl req -x509 -new -key "$OUT/ca.key" -sha256 -days "$DAYS_CA" \
  -subj "/O=Focus Companion/CN=Focus Companion Local CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$OUT/ca.crt"

# 2. Broker certificate (hostname 'mosquitto' inside Docker, 'localhost' outside)
sign server mosquitto "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:mosquitto,DNS:localhost,IP:127.0.0.1"

# 3. One client certificate per service; the CN becomes its MQTT identity
for c in "${CLIENTS[@]}"; do
  sign "$c" "$c" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth"
done

echo "Done. Files in certs/$OUT:"; ls -l "$OUT"
