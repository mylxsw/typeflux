#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
RELEASE_VARIANT="${TYPEFLUX_RELEASE_VARIANT:-minimal}"
DEFAULT_PACKAGE_NAME="$APP_NAME"
if [[ "$RELEASE_VARIANT" == "full" ]]; then
  DEFAULT_PACKAGE_NAME="${APP_NAME}-full"
fi
PACKAGE_NAME="${TYPEFLUX_PACKAGE_NAME:-$DEFAULT_PACKAGE_NAME}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="${PACKAGE_NAME}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
STAGING_DIR="${BUILD_DIR}/dmg-staging"

verify_bundle_signature() {
  local bundle_path="$1"

  command -v codesign >/dev/null 2>&1 || return 0

  if codesign -dv "$bundle_path" >/dev/null 2>&1; then
    codesign --verify --deep --strict --verbose=2 "$bundle_path"
  fi
}

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "Error: create-dmg is not installed. Install it with: brew install create-dmg"
  exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Error: $APP_BUNDLE not found. Run './scripts/build_release.sh' first."
  exit 1
fi

echo "Creating DMG package for $PACKAGE_NAME..."

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Preserve bundle metadata/signature while staging the app for DMG creation.
verify_bundle_signature "$APP_BUNDLE"
ditto "$APP_BUNDLE" "$STAGING_DIR/${APP_NAME}.app"
verify_bundle_signature "$STAGING_DIR/${APP_NAME}.app"

rm -f "$DMG_PATH"

create-dmg \
  --volname "$PACKAGE_NAME" \
  --window-size 800 400 \
  --icon-size 100 \
  --app-drop-link 600 185 \
  --icon "${APP_NAME}.app" 200 185 \
  "$DMG_PATH" \
  "$STAGING_DIR"

rm -rf "$STAGING_DIR"

# Sign the DMG if a signing identity is available
if [[ -n "${TYPEFLUX_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --sign "$TYPEFLUX_CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
  echo "Signed DMG with identity: $TYPEFLUX_CODESIGN_IDENTITY"
fi

echo "DMG created: $DMG_PATH"
