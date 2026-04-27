#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="Typeflux Dev"

if security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Certificate '$CERT_NAME' already exists in keychain."
  exit 0
fi

echo "Creating self-signed code-signing certificate: $CERT_NAME"
echo "You will be prompted for your keychain password to import the certificate."
echo "After that, the first 'make run' will ask for codesign access — click 'Always Allow'."
echo "Subsequent builds will work without any prompts."
echo ""

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

openssl req -x509 -newkey rsa:2048 \
  -keyout "$TEMP_DIR/typeflux_dev.key" \
  -out "$TEMP_DIR/typeflux_dev.crt" \
  -days 3650 -nodes \
  -subj "/CN=$CERT_NAME" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export \
  -inkey "$TEMP_DIR/typeflux_dev.key" \
  -in "$TEMP_DIR/typeflux_dev.crt" \
  -out "$TEMP_DIR/typeflux_dev.p12" \
  -passout pass:typeflux

echo ""
security import "$TEMP_DIR/typeflux_dev.p12" \
  -k ~/Library/Keychains/login.keychain-db \
  -f pkcs12 \
  -P typeflux

echo ""
echo "Certificate '$CERT_NAME' imported successfully."
echo "Run 'make run' to build with stable signing. Grant 'Always Allow' on the first codesign prompt."
