#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
RELEASE_VARIANT="${TYPEFLUX_RELEASE_VARIANT:-minimal}"
RELEASE_ARCH="${TYPEFLUX_RELEASE_ARCH:-native}"
DEFAULT_PACKAGE_NAME="$APP_NAME"
if [[ "$RELEASE_VARIANT" == "full" ]]; then
  DEFAULT_PACKAGE_NAME="${APP_NAME}-full"
elif [[ "$RELEASE_VARIANT" == "app-only" ]]; then
  DEFAULT_PACKAGE_NAME="${APP_NAME}-app-only"
fi
case "$RELEASE_ARCH" in
  native)
    ;;
  arm64)
    DEFAULT_PACKAGE_NAME="${DEFAULT_PACKAGE_NAME}-apple-silicon"
    ;;
  x86_64)
    DEFAULT_PACKAGE_NAME="${DEFAULT_PACKAGE_NAME}-intel"
    ;;
  universal)
    DEFAULT_PACKAGE_NAME="${DEFAULT_PACKAGE_NAME}-universal"
    ;;
  *)
    echo "Error: unsupported TYPEFLUX_RELEASE_ARCH: ${RELEASE_ARCH}" >&2
    exit 1
    ;;
esac
PACKAGE_NAME="${TYPEFLUX_PACKAGE_NAME:-$DEFAULT_PACKAGE_NAME}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="${PACKAGE_NAME}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
STAGING_DIR="${BUILD_DIR}/dmg-staging"

is_truthy() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

verify_bundle_signature() {
  local bundle_path="$1"

  if ! command -v codesign >/dev/null 2>&1; then
    echo "Warning: codesign not available; skipping signature verification for $bundle_path" >&2
    return 0
  fi

  if codesign -dv "$bundle_path" >/dev/null 2>&1; then
    codesign --verify --deep --strict --verbose=2 "$bundle_path"
  fi
}

source "$ROOT_DIR/scripts/signing_keychain.sh"
if [[ -n "${TYPEFLUX_CODESIGN_IDENTITY:-}" ]]; then
  select_signing_identity release "$TYPEFLUX_CODESIGN_IDENTITY" "${TYPEFLUX_CODESIGN_KEYCHAIN:-}"
fi

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

CREATE_DMG_ARGS=(
  --volname "$PACKAGE_NAME"
  --window-size 800 400
  --icon-size 100
  --app-drop-link 600 185
  --icon "${APP_NAME}.app" 200 185
)

if is_truthy "${TYPEFLUX_DMG_FINDER_LAYOUT:-}"; then
  echo "Finder DMG layout enabled; create-dmg may require Automation permission for Finder."
else
  echo "Skipping Finder DMG layout to avoid macOS Automation permission prompts."
  CREATE_DMG_ARGS+=(--skip-jenkins)
fi

create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$STAGING_DIR"

rm -rf "$STAGING_DIR"

# Sign the DMG if a signing identity is available
if [[ -n "${TYPEFLUX_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --keychain "$signing_keychain" --force --sign "$signing_hash" --timestamp "$DMG_PATH"
  echo "Signed DMG with identity: $TYPEFLUX_CODESIGN_IDENTITY"
fi

echo "DMG created: $DMG_PATH"
