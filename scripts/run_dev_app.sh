#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${TYPEFLUX_DEV_APP_DIR:-${VOICEINPUT_DEV_APP_DIR:-$HOME/Applications/Typeflux Dev.app}}"

swift build --package-path "$ROOT_DIR" -c debug

BIN="$ROOT_DIR/.build/debug/Typeflux"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Keep the .app path stable to avoid macOS privacy permission re-prompts.
cp "$ROOT_DIR/app/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BIN" "$APP_DIR/Contents/MacOS/Typeflux"
cp "$ROOT_DIR/app/Typeflux.icns" "$APP_DIR/Contents/Resources/Typeflux.icns"

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

if [[ -z "${DEV_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --identifier "dev.typeflux" "$APP_DIR"
fi

# If you want a fully stable identity across machines and clean TCC behavior,
# provide an explicit signing identity instead of the fallback dev signature.
# If you want signing, provide a stable identity explicitly:
#   DEV_CODESIGN_IDENTITY="Apple Development: Your Name (...)" ./scripts/run_dev_app.sh
if [[ -n "${DEV_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$DEV_CODESIGN_IDENTITY" "$APP_DIR"
  echo "Signed with stable identity: $DEV_CODESIGN_IDENTITY"
else
  echo "Warning: using ad-hoc signing. Accessibility permission may need to be re-granted across rebuilds."
fi

open "$APP_DIR"

echo "App launched: $APP_DIR"
