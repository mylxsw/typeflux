#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
APP_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"

create_zip_archive() {
  rm -f "$ZIP_PATH"
  (
    cd "$BUILD_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
  )
}

echo "Building Typeflux release bundle..."

swift build --package-path "$ROOT_DIR" -c release

BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --show-bin-path)"
BIN="$BIN_DIR/Typeflux"
RESOURCE_BUNDLE="$BIN_DIR/Typeflux_Typeflux.bundle"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$ROOT_DIR/app/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/Typeflux"
cp "$ROOT_DIR/app/Typeflux.icns" "$APP_BUNDLE/Contents/Resources/Typeflux.icns"
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/Typeflux_Typeflux.bundle"

chmod +x "$APP_BUNDLE/Contents/MacOS/Typeflux"

ENTITLEMENTS="$ROOT_DIR/app/Typeflux.entitlements"
TYPEFLUX_PROVISIONING_PROFILE="${TYPEFLUX_PROVISIONING_PROFILE:-}"

# Sign In with Apple requires both the entitlement and an embedded macOS
# provisioning profile whose App ID matches dev.typeflux. Without the profile,
# AMFI rejects the app at launch when restricted entitlements are present, so
# we fall back to signing without entitlements and warn the operator.
use_apple_sign_in_entitlements=false
if [[ -n "$TYPEFLUX_PROVISIONING_PROFILE" ]]; then
  if [[ -f "$TYPEFLUX_PROVISIONING_PROFILE" ]]; then
    cp "$TYPEFLUX_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    use_apple_sign_in_entitlements=true
  else
    echo "Warning: TYPEFLUX_PROVISIONING_PROFILE does not exist: $TYPEFLUX_PROVISIONING_PROFILE"
    rm -f "$APP_BUNDLE/Contents/embedded.provisionprofile"
  fi
else
  rm -f "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi

# Sign the bundle if an identity is available.
# Hardened runtime is required for notarization with a Developer ID signature.
if [[ -n "${TYPEFLUX_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign_args=(
    --force
    --sign "$TYPEFLUX_CODESIGN_IDENTITY"
    --timestamp
    --options runtime
    --identifier "dev.typeflux"
  )
  if [[ "$use_apple_sign_in_entitlements" == true ]]; then
    codesign_args+=(--entitlements "$ENTITLEMENTS")
  fi
  codesign "${codesign_args[@]}" "$APP_EXECUTABLE"
  codesign "${codesign_args[@]}" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  echo "Signed with identity: $TYPEFLUX_CODESIGN_IDENTITY"
elif command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --identifier "dev.typeflux" "$APP_EXECUTABLE"
  codesign --force --sign - --identifier "dev.typeflux" "$APP_BUNDLE"
  echo "Signed with ad-hoc identity"
fi

if [[ "$use_apple_sign_in_entitlements" == true ]]; then
  echo "Embedded provisioning profile: $TYPEFLUX_PROVISIONING_PROFILE"
else
  echo "Warning: Sign In with Apple is disabled for this release build."
  echo "Warning: To enable it, set TYPEFLUX_PROVISIONING_PROFILE to a macOS provisioning profile whose App ID matches dev.typeflux and includes the Sign In with Apple capability."
fi

create_zip_archive

echo "Release bundle created: $APP_BUNDLE"
echo "Release archive created: $ZIP_PATH"
