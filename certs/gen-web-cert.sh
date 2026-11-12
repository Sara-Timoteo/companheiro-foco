#!/usr/bin/env bash
# HTTPS for the dashboard on this computer.
# Uses its own CA that can only sign certificates for localhost (X.509 name constraints),
# so trusting it in a browser cannot be abused for any other site.
set -euo pipefail
cd "$(dirname "$0")"

OUT=out
if [[ -f "$OUT/web.crt" && "${1:-}" != "--force" ]]; then
  echo "certs/out/web.crt already exists. Run with --force to regenerate."; exit 0
fi
umask 077; mkdir -p "$OUT"

newkey() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }

newkey "$OUT/web-ca.key"
openssl req -x509 -new -key "$OUT/web-ca.key" -sha256 -days 365 \
  -subj "/O=Focus Companion/CN=Focus Companion localhost-only CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "nameConstraints=critical,permitted;DNS:localhost,permitted;IP:127.0.0.1/255.255.255.255" \
  -out "$OUT/web-ca.crt"

newkey "$OUT/web.key"
openssl req -new -key "$OUT/web.key" -subj "/O=Focus Companion/CN=localhost" -out "$OUT/web.csr"
openssl x509 -req -in "$OUT/web.csr" -CA "$OUT/web-ca.crt" -CAkey "$OUT/web-ca.key" -CAcreateserial \
  -sha256 -days 90 -out "$OUT/web.crt" 2>/dev/null \
  -extfile <(printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature" \
             "extendedKeyUsage=serverAuth" "subjectAltName=DNS:localhost,IP:127.0.0.1")
rm "$OUT/web.csr"

echo "Done. Trust certs/out/web-ca.crt in your browser; the dashboard uses web.crt and web.key."
