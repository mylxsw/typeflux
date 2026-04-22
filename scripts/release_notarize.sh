#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
PACKAGE_NAME="${TYPEFLUX_PACKAGE_NAME:-$APP_NAME}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${PACKAGE_NAME}.dmg"
ZIP_PATH="${BUILD_DIR}/${PACKAGE_NAME}.zip"
TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS="${TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS:-15}"
TYPEFLUX_NOTARY_SUBMIT_RETRIES="${TYPEFLUX_NOTARY_SUBMIT_RETRIES:-3}"
TYPEFLUX_NOTARY_KEYCHAIN="${TYPEFLUX_NOTARY_KEYCHAIN:-}"

TYPEFLUX_CODESIGN_IDENTITY="${TYPEFLUX_CODESIGN_IDENTITY:-${TYPEFLUX_DEVELOPER_ID_APPLICATION:-${TYPEFLUX_APPLE_DISTRIBUTION:-}}}"
export TYPEFLUX_CODESIGN_IDENTITY

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
}

require_env() {
  local env_name="$1"

  [[ -n "${!env_name:-}" ]] || fail "Missing required environment variable: $env_name"
}

parse_notary_field() {
  local field_name="$1"
  local raw_output="$2"

  awk -F': ' -v key="$field_name" '$1 ~ key"$" {print $2; exit}' <<<"$raw_output"
}

find_valid_codesign_identity() {
  local requested_identity="$1"

  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p' \
    | while IFS= read -r identity; do
      [[ -n "$identity" ]] || continue

      if [[ -n "$requested_identity" ]]; then
        [[ "$identity" == "$requested_identity" ]] && printf '%s\n' "$identity"
      elif [[ "$identity" == Developer\ ID\ Application:* ]]; then
        printf '%s\n' "$identity"
        break
      fi
    done
}

codesign_identity_exists_as_certificate() {
  local identity_name="$1"
  security find-certificate -a -c "$identity_name" >/dev/null 2>&1
}

resolve_codesign_identity() {
  local requested_identity="${TYPEFLUX_CODESIGN_IDENTITY:-}"
  local resolved_identity

  resolved_identity="$(find_valid_codesign_identity "$requested_identity" | head -n 1)"
  if [[ -n "$resolved_identity" ]]; then
    TYPEFLUX_CODESIGN_IDENTITY="$resolved_identity"
    export TYPEFLUX_CODESIGN_IDENTITY
    return 0
  fi

  if [[ -n "$requested_identity" ]] && codesign_identity_exists_as_certificate "$requested_identity"; then
    fail "Signing certificate '${requested_identity}' exists in Keychain, but no valid signing identity was found. The private key is likely missing from this Mac."
  fi

  fail "No valid Developer ID Application signing identity found. Import or create a Developer ID Application certificate with its private key, or set TYPEFLUX_CODESIGN_IDENTITY to a valid identity from 'security find-identity -v -p codesigning'."
}

run_notarytool() {
  local subcommand="$1"
  shift

  local args=("$subcommand" "$@" --keychain-profile "$TYPEFLUX_NOTARY_PROFILE")

  if [[ -n "$TYPEFLUX_NOTARY_KEYCHAIN" ]]; then
    args+=(--keychain "$TYPEFLUX_NOTARY_KEYCHAIN")
  fi

  xcrun notarytool "${args[@]}"
}

submit_for_notarization() {
  local attempt submit_log submit_output submission_id

  for attempt in $(seq 1 "$TYPEFLUX_NOTARY_SUBMIT_RETRIES"); do
    log "Submitting ${DMG_PATH} for notarization (attempt ${attempt}/${TYPEFLUX_NOTARY_SUBMIT_RETRIES})..."
    submit_log="$(mktemp)"

    if run_notarytool submit "$DMG_PATH" --no-wait 2>&1 | tee "$submit_log" >&2; then
      submit_output="$(<"$submit_log")"
      submission_id="$(parse_notary_field "id" "$submit_output")"
      rm -f "$submit_log"
      [[ -n "$submission_id" ]] || fail "Unable to parse notarization submission ID."
      echo "$submission_id"
      return 0
    fi

    submit_output="$(<"$submit_log")"
    submission_id="$(parse_notary_field "id" "$submit_output")"
    rm -f "$submit_log"
    if [[ -n "$submission_id" ]]; then
      log "Submit command returned an error after receiving submission ID ${submission_id}. Continuing with that submission."
      echo "$submission_id"
      return 0
    fi

    if [[ "$attempt" -lt "$TYPEFLUX_NOTARY_SUBMIT_RETRIES" ]]; then
      log "Submission failed, retrying in 10 seconds..."
      sleep 10
      continue
    fi

    fail "Notarization submission failed after ${TYPEFLUX_NOTARY_SUBMIT_RETRIES} attempts."
  done
}

wait_for_notarization() {
  local submission_id="$1"
  local info_output submission_status

  while true; do
    info_output="$(
      run_notarytool info "$submission_id" 2>&1
    )"
    submission_status="$(parse_notary_field "status" "$info_output")"

    [[ -n "$submission_status" ]] || fail "Unable to parse notarization status.\n${info_output}"
    log "Current notarization status: ${submission_status}"

    case "$submission_status" in
      "Accepted")
        return 0
        ;;
      "In Progress")
        sleep "$TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS"
        ;;
      *)
        echo "$info_output" >&2
        log "Fetching notarization log for ${submission_id}..."
        run_notarytool log "$submission_id" || true
        fail "Notarization failed with status: ${submission_status}"
        ;;
    esac
  done
}

staple_artifacts() {
  log "Stapling notarization ticket to ${APP_BUNDLE}..."
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"

  log "Stapling notarization ticket to ${DMG_PATH}..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
}

refresh_zip_archive() {
  log "Refreshing ZIP archive after stapling..."
  rm -f "$ZIP_PATH"
  (
    cd "$BUILD_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$PACKAGE_NAME.zip"
  )
}

main() {
  local submission_id

  require_command swift
  require_command codesign
  require_command xcrun
  require_command create-dmg
  require_env TYPEFLUX_NOTARY_PROFILE
  resolve_codesign_identity

  log "Using signing identity: ${TYPEFLUX_CODESIGN_IDENTITY}"
  log "Using notary profile: ${TYPEFLUX_NOTARY_PROFILE}"
  log "Using package name: ${PACKAGE_NAME}"

  log "Building signed release app..."
  "${ROOT_DIR}/scripts/build_release.sh"

  log "Building signed DMG..."
  "${ROOT_DIR}/scripts/build_dmg.sh"

  submission_id="$(submit_for_notarization)"
  log "Notarization submission ID: ${submission_id}"

  wait_for_notarization "$submission_id"
  staple_artifacts
  refresh_zip_archive

  log "Release workflow completed successfully."
  log "App: ${APP_BUNDLE}"
  log "ZIP: ${ZIP_PATH}"
  log "DMG: ${DMG_PATH}"
}

main "$@"
