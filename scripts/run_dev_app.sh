#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${TYPEFLUX_DEV_APP_DIR:-${TYPEFLUX_DEV_APP_DIR:-$HOME/Applications/Typeflux Dev.app}}"

swift build --package-path "$ROOT_DIR" -c debug

BIN_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
BIN="$BIN_DIR/Typeflux"
RESOURCE_BUNDLE="$BIN_DIR/Typeflux_Typeflux.bundle"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Keep the .app path stable to avoid macOS privacy permission re-prompts.
cp "$ROOT_DIR/app/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BIN" "$APP_DIR/Contents/MacOS/Typeflux"
cp "$ROOT_DIR/app/Typeflux.icns" "$APP_DIR/Contents/Resources/Typeflux.icns"
rm -rf "$APP_DIR/Contents/Resources/Typeflux_Typeflux.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/Typeflux_Typeflux.bundle"

set_plist_value() {
  local key="$1"
  local value="$2"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP_DIR/Contents/Info.plist"
}

for key in TYPEFLUX_API_URL GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GITHUB_OAUTH_CLIENT_ID; do
  if [[ -n "${!key:-}" ]]; then
    set_plist_value "$key" "${!key}"
  fi
done

chmod +x "$APP_DIR/Contents/MacOS/Typeflux"

# SwiftPM debug builds may carry a transient ad-hoc signature with a generated
# identifier. Re-sign the assembled app bundle with a stable identifier so the
# dev app is launchable and privacy services see a consistent app identity.
if [[ -z "${DEV_CODESIGN_IDENTITY:-}" ]] && command -v security >/dev/null 2>&1; then
  DEV_CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"Apple Development: \(.*\)"/Apple Development: \1/p' \
      | head -n 1
  )"
fi

ENTITLEMENTS="$ROOT_DIR/app/Typeflux.entitlements"

# Ad-hoc signing: entitlements are embedded but Sign In with Apple will not
# work at runtime — Apple's servers reject tokens from ad-hoc-signed binaries.
# Use a real Apple Development identity (DEV_CODESIGN_IDENTITY) for full functionality.
if [[ -z "${DEV_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --identifier "dev.typeflux" \
    --entitlements "$ENTITLEMENTS" "$APP_DIR"
fi

# If you want a fully stable identity across machines and clean TCC behavior,
# provide an explicit signing identity instead of the fallback dev signature.
# Sign In with Apple REQUIRES a real Apple Development identity:
#   DEV_CODESIGN_IDENTITY="Apple Development: Your Name (...)" ./scripts/run_dev_app.sh
if [[ -n "${DEV_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$DEV_CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$APP_DIR"
  echo "Signed with stable identity: $DEV_CODESIGN_IDENTITY"
else
  echo "Warning: using ad-hoc signing. Sign In with Apple requires a real Apple Development identity."
fi

open "$APP_DIR"

echo "App launched: $APP_DIR"
