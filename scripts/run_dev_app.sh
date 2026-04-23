#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${TYPEFLUX_DEV_APP_DIR:-${TYPEFLUX_DEV_APP_DIR:-$HOME/Applications/Typeflux Dev.app}}"
DEV_VARIANT="${TYPEFLUX_DEV_VARIANT:-minimal}"

profile_supports_apple_sign_in() {
  local profile_path="$1"
  local decoded_profile
  decoded_profile="$(mktemp "${TMPDIR:-/tmp}/typeflux-profile.XXXXXX")"

  if ! security cms -D -i "$profile_path" >"$decoded_profile" 2>/dev/null; then
    rm -f "$decoded_profile"
    return 1
  fi

  local entitlement_output
  entitlement_output="$(
    /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.applesignin" "$decoded_profile" 2>/dev/null \
      || true
  )"
  rm -f "$decoded_profile"

  [[ "$entitlement_output" == *"Default"* ]]
}

install_bundled_models() {
  local bundled_models_dir="$APP_DIR/Contents/Resources/BundledModels"
  rm -rf "$bundled_models_dir"

  case "$DEV_VARIANT" in
    minimal)
      ;;
    full)
      local target_model_folder="$bundled_models_dir/senseVoiceSmall/sensevoice-small"
      "${ROOT_DIR}/scripts/install_bundled_sensevoice.sh" "$target_model_folder"

      local expected_model_file="$target_model_folder/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx"
      if [[ ! -f "$expected_model_file" ]]; then
        echo "Error: bundled SenseVoice model missing at $expected_model_file" >&2
        exit 1
      fi
      ;;
    *)
      echo "Error: unsupported TYPEFLUX_DEV_VARIANT: ${DEV_VARIANT}" >&2
      exit 1
      ;;
  esac
}

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
install_bundled_models

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
if [[ -z "${TYPEFLUX_DEV_CODESIGN_IDENTITY:-}" ]] && command -v security >/dev/null 2>&1; then
  TYPEFLUX_DEV_CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"Apple Development: \(.*\)"/Apple Development: \1/p' \
      | head -n 1
  )"
fi

RUNTIME_ENTITLEMENTS="$ROOT_DIR/app/TypefluxRuntime.entitlements"
APPLE_SIGN_IN_ENTITLEMENTS="$ROOT_DIR/app/Typeflux.entitlements"
TYPEFLUX_DEV_PROVISIONING_PROFILE="${TYPEFLUX_DEV_PROVISIONING_PROFILE:-}"

use_apple_sign_in_entitlements=false
if [[ -n "$TYPEFLUX_DEV_PROVISIONING_PROFILE" ]]; then
  if [[ -f "$TYPEFLUX_DEV_PROVISIONING_PROFILE" ]]; then
    cp "$TYPEFLUX_DEV_PROVISIONING_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
    if profile_supports_apple_sign_in "$TYPEFLUX_DEV_PROVISIONING_PROFILE"; then
      use_apple_sign_in_entitlements=true
    else
      echo "Warning: embedded provisioning profile does not grant Sign In with Apple."
      echo "Warning: signing dev app with runtime-only entitlements so it can still launch."
    fi
  else
    echo "Warning: TYPEFLUX_DEV_PROVISIONING_PROFILE does not exist: $TYPEFLUX_DEV_PROVISIONING_PROFILE"
    rm -f "$APP_DIR/Contents/embedded.provisionprofile"
  fi
else
  rm -f "$APP_DIR/Contents/embedded.provisionprofile"
fi

if [[ "$use_apple_sign_in_entitlements" == true ]] && [[ -z "${TYPEFLUX_DEV_CODESIGN_IDENTITY:-}" ]]; then
  use_apple_sign_in_entitlements=false
  echo "Warning: provisioning profile grants Sign In with Apple, but no Apple Development signing identity was found."
  echo "Warning: signing dev app with runtime-only entitlements so it can still launch."
fi

entitlements_to_use="$RUNTIME_ENTITLEMENTS"
if [[ "$use_apple_sign_in_entitlements" == true ]]; then
  entitlements_to_use="$APPLE_SIGN_IN_ENTITLEMENTS"
fi

# Sign In with Apple on manually assembled macOS app bundles requires both:
# 1. A real Apple Development identity
# 2. A matching macOS provisioning profile embedded at Contents/embedded.provisionprofile
# Without the provisioning profile, AMFI rejects the app at launch if restricted
# entitlements are present. In that case we keep the app launchable and disable
# Sign In with Apple for the dev build.
if [[ -z "${TYPEFLUX_DEV_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --identifier "ai.gulu.app.typeflux" \
    --entitlements "$entitlements_to_use" "$APP_DIR"
fi

# If you want a fully stable identity across machines and clean TCC behavior,
# provide an explicit signing identity instead of the fallback dev signature.
# Sign In with Apple REQUIRES both a real Apple Development identity and a
# matching macOS provisioning profile:
#   TYPEFLUX_DEV_PROVISIONING_PROFILE="/path/to/profile.provisionprofile" \
#   TYPEFLUX_DEV_CODESIGN_IDENTITY="Apple Development: Your Name (...)" ./scripts/run_dev_app.sh
if [[ -n "${TYPEFLUX_DEV_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$TYPEFLUX_DEV_CODESIGN_IDENTITY" \
    --entitlements "$entitlements_to_use" "$APP_DIR"
  echo "Signed with stable identity: $TYPEFLUX_DEV_CODESIGN_IDENTITY"
else
  echo "Warning: using ad-hoc signing. Sign In with Apple requires a real Apple Development identity and matching provisioning profile."
fi

if [[ "$use_apple_sign_in_entitlements" == true ]]; then
  echo "Embedded provisioning profile: $TYPEFLUX_DEV_PROVISIONING_PROFILE"
else
  echo "Warning: Sign In with Apple is disabled for this dev build."
  echo "Warning: To enable it, provide TYPEFLUX_DEV_PROVISIONING_PROFILE with a matching macOS provisioning profile that includes the Sign In with Apple capability."
fi

open "$APP_DIR"

echo "App launched: $APP_DIR"
echo "Dev variant: $DEV_VARIANT"
