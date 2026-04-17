#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
STAGING_DIR="${BUILD_DIR}/dmg-staging"

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "Error: create-dmg is not installed. Install it with: brew install create-dmg"
  exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Error: $APP_BUNDLE not found. Run './scripts/build_release.sh' first."
  exit 1
fi

echo "Creating DMG for $APP_NAME..."

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"

create-dmg \
  --volname "$APP_NAME" \
  --window-size 800 400 \
  --icon-size 100 \
  --app-drop-link 600 185 \
  --icon "${APP_NAME}.app" 200 185 \
  "$DMG_PATH" \
  "$STAGING_DIR"

rm -rf "$STAGING_DIR"

# Sign the DMG if a signing identity is available
if [[ -n "${CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
  echo "Signed DMG with identity: $CODESIGN_IDENTITY"
fi

echo "DMG created: $DMG_PATH"
