#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/release"
APP_NAME="Typeflux"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
NOTARY_POLL_INTERVAL_SECONDS="${NOTARY_POLL_INTERVAL_SECONDS:-15}"
NOTARY_SUBMIT_RETRIES="${NOTARY_SUBMIT_RETRIES:-3}"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-${APPLE_DISTRIBUTION:-}}"
export CODESIGN_IDENTITY

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

submit_for_notarization() {
  local attempt submit_log submit_output submission_id

  for attempt in $(seq 1 "$NOTARY_SUBMIT_RETRIES"); do
    log "Submitting ${DMG_PATH} for notarization (attempt ${attempt}/${NOTARY_SUBMIT_RETRIES})..."
    submit_log="$(mktemp)"

    if xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" 2>&1 | tee "$submit_log" >&2; then
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

    if [[ "$attempt" -lt "$NOTARY_SUBMIT_RETRIES" ]]; then
      log "Submission failed, retrying in 10 seconds..."
      sleep 10
      continue
    fi

    fail "Notarization submission failed after ${NOTARY_SUBMIT_RETRIES} attempts."
  done
}

wait_for_notarization() {
  local submission_id="$1"
  local info_output submission_status

  while true; do
    info_output="$(
      xcrun notarytool info "$submission_id" --keychain-profile "$NOTARY_PROFILE" 2>&1
    )"
    submission_status="$(parse_notary_field "status" "$info_output")"

    [[ -n "$submission_status" ]] || fail "Unable to parse notarization status.\n${info_output}"
    log "Current notarization status: ${submission_status}"

    case "$submission_status" in
      "Accepted")
        return 0
        ;;
      "In Progress")
        sleep "$NOTARY_POLL_INTERVAL_SECONDS"
        ;;
      *)
        echo "$info_output" >&2
        log "Fetching notarization log for ${submission_id}..."
        xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true
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

main() {
  local submission_id

  require_command swift
  require_command codesign
  require_command xcrun
  require_command create-dmg
  require_env CODESIGN_IDENTITY
  require_env NOTARY_PROFILE

  log "Using signing identity: ${CODESIGN_IDENTITY}"
  log "Using notary profile: ${NOTARY_PROFILE}"

  log "Building signed release app..."
  "${ROOT_DIR}/scripts/build_release.sh"

  log "Building signed DMG..."
  "${ROOT_DIR}/scripts/build_dmg.sh"

  submission_id="$(submit_for_notarization)"
  log "Notarization submission ID: ${submission_id}"

  wait_for_notarization "$submission_id"
  staple_artifacts

  log "Release workflow completed successfully."
  log "App: ${APP_BUNDLE}"
  log "DMG: ${DMG_PATH}"
}

main "$@"
