#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

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

# Sign the bundle if an identity is available
if [[ -n "${CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier "dev.typeflux" "$APP_BUNDLE"
  echo "Signed with identity: $CODESIGN_IDENTITY"
elif command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --identifier "dev.typeflux" "$APP_BUNDLE"
  echo "Signed with ad-hoc identity"
fi

# Create a ZIP archive for distribution
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
rm -f "$ZIP_PATH"
(
  cd "$BUILD_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
)

echo "Release bundle created: $APP_BUNDLE"
echo "Release archive created: $ZIP_PATH"
