#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
RELEASE_VARIANT="${TYPEFLUX_RELEASE_VARIANT:-minimal}"
DEFAULT_PACKAGE_NAME="$APP_NAME"
if [[ "$RELEASE_VARIANT" == "full" ]]; then
  DEFAULT_PACKAGE_NAME="${APP_NAME}-full"
elif [[ "$RELEASE_VARIANT" == "app-only" ]]; then
  DEFAULT_PACKAGE_NAME="${APP_NAME}-app-only"
fi
PACKAGE_NAME="${TYPEFLUX_PACKAGE_NAME:-$DEFAULT_PACKAGE_NAME}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
APP_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
ZIP_PATH="${BUILD_DIR}/${PACKAGE_NAME}.zip"

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

create_zip_archive() {
  rm -f "$ZIP_PATH"
  (
    cd "$BUILD_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$PACKAGE_NAME.zip"
  )
}

echo "Building Typeflux release bundle..."
echo "Release variant: ${RELEASE_VARIANT}"

case "$RELEASE_VARIANT" in
  minimal|full|app-only)
    ;;
  *)
    echo "Error: unsupported TYPEFLUX_RELEASE_VARIANT: ${RELEASE_VARIANT}" >&2
    exit 1
    ;;
esac

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

rm -rf "$APP_BUNDLE/Contents/Resources/BundledModels"
rm -rf "$APP_BUNDLE/Contents/Resources/LocalRuntimes"
SHERPA_RUNTIME_ROOT="$APP_BUNDLE/Contents/Resources/LocalRuntimes/sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts"
if [[ "$RELEASE_VARIANT" != "app-only" ]]; then
  "${ROOT_DIR}/scripts/install_bundled_sherpa_runtime.sh" "$SHERPA_RUNTIME_ROOT"
fi

if [[ "$RELEASE_VARIANT" == "full" ]]; then
  # Directory name must match LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
  # so that BundledLocalModelLocator resolves the bundled copy at runtime.
  BUNDLED_SENSEVOICE_DIR="$APP_BUNDLE/Contents/Resources/BundledModels/senseVoiceSmall/sensevoice-small"
  "${ROOT_DIR}/scripts/install_bundled_sensevoice.sh" "$BUNDLED_SENSEVOICE_DIR" "$SHERPA_RUNTIME_ROOT"

  expected_model_file="$BUNDLED_SENSEVOICE_DIR/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx"
  if [[ ! -f "$expected_model_file" ]]; then
    echo "Error: bundled SenseVoice model missing at $expected_model_file" >&2
    exit 1
  fi
fi

chmod +x "$APP_BUNDLE/Contents/MacOS/Typeflux"

RUNTIME_ENTITLEMENTS="$ROOT_DIR/app/TypefluxRuntime.entitlements"
APPLE_SIGN_IN_ENTITLEMENTS="$ROOT_DIR/app/Typeflux.entitlements"
TYPEFLUX_PROVISIONING_PROFILE="${TYPEFLUX_PROVISIONING_PROFILE:-}"

# Sign In with Apple requires both the entitlement and an embedded macOS
# provisioning profile whose App ID matches ai.gulu.app.typeflux. Without the profile,
# AMFI rejects the app at launch when restricted entitlements are present, so
# we fall back to runtime-only entitlements and warn the operator.
use_apple_sign_in_entitlements=false
if [[ -n "$TYPEFLUX_PROVISIONING_PROFILE" ]]; then
  if [[ -f "$TYPEFLUX_PROVISIONING_PROFILE" ]]; then
    cp "$TYPEFLUX_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    if profile_supports_apple_sign_in "$TYPEFLUX_PROVISIONING_PROFILE"; then
      use_apple_sign_in_entitlements=true
    else
      echo "Warning: embedded provisioning profile does not grant Sign In with Apple."
      echo "Warning: signing release bundle with runtime-only entitlements so it remains launchable."
    fi
  else
    echo "Warning: TYPEFLUX_PROVISIONING_PROFILE does not exist: $TYPEFLUX_PROVISIONING_PROFILE"
    rm -f "$APP_BUNDLE/Contents/embedded.provisionprofile"
  fi
else
  rm -f "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi

entitlements_to_use="$RUNTIME_ENTITLEMENTS"
if [[ "$use_apple_sign_in_entitlements" == true ]]; then
  entitlements_to_use="$APPLE_SIGN_IN_ENTITLEMENTS"
fi

# Notarization requires every Mach-O inside the bundle to carry a Developer ID
# signature, a secure timestamp, and the hardened runtime. The `full` variant
# used to be the only variant with third-party sherpa-onnx binaries; now every
# variant ships the shared local runtime under Contents/Resources/LocalRuntimes.
# These upstream binaries must be signed individually before the outer bundle is
# sealed. `codesign --deep` is deprecated for this and does not cover arbitrary
# Mach-O files under Contents/Resources.
sign_nested_binaries() {
  local identity="$1"
  local adhoc="$2"
  local resources_root="$APP_BUNDLE/Contents/Resources"

  [[ -d "$resources_root" ]] || return 0

  local -a nested_args
  if [[ "$adhoc" == true ]]; then
    nested_args=(--force --sign - --identifier "ai.gulu.app.typeflux")
  else
    nested_args=(
      --force
      --sign "$identity"
      --timestamp
      --options runtime
    )
  fi

  while IFS= read -r -d '' candidate; do
    [[ -L "$candidate" ]] && continue
    if file "$candidate" 2>/dev/null | grep -qE 'Mach-O|dynamically linked shared library'; then
      echo "Signing nested binary: ${candidate#$APP_BUNDLE/}"
      codesign "${nested_args[@]}" "$candidate"
    fi
  done < <(find "$resources_root/LocalRuntimes" "$resources_root/BundledModels" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)
}

# Sign the bundle if an identity is available.
# Hardened runtime is required for notarization with a Developer ID signature.
if [[ -n "${TYPEFLUX_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign_args=(
    --force
    --sign "$TYPEFLUX_CODESIGN_IDENTITY"
    --timestamp
    --options runtime
    --identifier "ai.gulu.app.typeflux"
    --entitlements "$entitlements_to_use"
  )
  sign_nested_binaries "$TYPEFLUX_CODESIGN_IDENTITY" false
  codesign "${codesign_args[@]}" "$APP_EXECUTABLE"
  codesign "${codesign_args[@]}" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  echo "Signed with identity: $TYPEFLUX_CODESIGN_IDENTITY"
elif command -v codesign >/dev/null 2>&1; then
  sign_nested_binaries "" true
  codesign --force --sign - --identifier "ai.gulu.app.typeflux" \
    --entitlements "$entitlements_to_use" "$APP_EXECUTABLE"
  codesign --force --sign - --identifier "ai.gulu.app.typeflux" \
    --entitlements "$entitlements_to_use" "$APP_BUNDLE"
  echo "Signed with ad-hoc identity"
fi

if [[ "$use_apple_sign_in_entitlements" == true ]]; then
  echo "Embedded provisioning profile: $TYPEFLUX_PROVISIONING_PROFILE"
else
  echo "Warning: Sign In with Apple is disabled for this release build."
  echo "Warning: To enable it, set TYPEFLUX_PROVISIONING_PROFILE to a macOS provisioning profile whose App ID matches ai.gulu.app.typeflux and includes the Sign In with Apple capability."
fi

"${ROOT_DIR}/scripts/audit_macho_minos.sh" "$APP_BUNDLE" "${TYPEFLUX_MAX_MACHO_MINOS:-13.4}"

create_zip_archive

echo "Release bundle created: $APP_BUNDLE"
echo "Release archive created: $ZIP_PATH"
