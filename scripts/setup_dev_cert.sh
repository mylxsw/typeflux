#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="Typeflux Dev"
KEYCHAIN_NAME="typeflux-dev.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"

# Already set up?
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$CERT_NAME\""; then
  echo "Certificate '$CERT_NAME' is already a valid code-signing identity."
  exit 0
fi

echo "Creating self-signed code-signing certificate: $CERT_NAME"

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

# Create a dedicated project keychain with NO password — no prompts needed.
if [[ ! -f "$KEYCHAIN_PATH" ]]; then
  security create-keychain -p "" "$KEYCHAIN_PATH"
  security set-keychain-settings -t 3600 "$KEYCHAIN_PATH"
fi

security import "$TEMP_DIR/typeflux_dev.p12" \
  -k "$KEYCHAIN_PATH" \
  -f pkcs12 \
  -P typeflux \
  -T /usr/bin/codesign

security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "" "$KEYCHAIN_PATH" 2>/dev/null || true

security add-trusted-cert -d -p codeSign \
  -k "$KEYCHAIN_PATH" \
  "$TEMP_DIR/typeflux_dev.crt"

# Register this keychain in the user dashboard search list so codesign and
# security find-identity see the new identity.
security list-keychains -d user -s \
  "$(security list-keychains -d user 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
  "$KEYCHAIN_PATH" \
  2>/dev/null || security list-keychains -d user -s "$KEYCHAIN_PATH"

echo ""
echo "Certificate '$CERT_NAME' created and trusted for code signing."
echo "Run 'make run' — no password prompts needed."
echo "Keychain: $KEYCHAIN_PATH"
