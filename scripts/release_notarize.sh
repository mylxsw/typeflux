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
DMG_PATH="${BUILD_DIR}/${PACKAGE_NAME}.dmg"
ZIP_PATH="${BUILD_DIR}/${PACKAGE_NAME}.zip"
STATE_PATH="${TYPEFLUX_RELEASE_STATE_PATH:-${BUILD_DIR}/.release-workflow.env}"
DESTINATION_DIR="${TYPEFLUX_RELEASE_DESTINATION:-${HOME}/Downloads}"
TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS="${TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS:-15}"
TYPEFLUX_NOTARY_SUBMIT_RETRIES="${TYPEFLUX_NOTARY_SUBMIT_RETRIES:-3}"
TYPEFLUX_NOTARY_KEYCHAIN="${TYPEFLUX_NOTARY_KEYCHAIN:-}"
CONTINUE_RELEASE=false
MOVE_TO_DOWNLOADS=false
RELEASE_STAGE="new"
SUBMISSION_ID=""

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

usage() {
  cat >&2 <<'EOF'
Usage: scripts/release_notarize.sh [--continue] [--move-to-downloads]

Options:
  --continue           Resume the release recorded in .build/release/.release-workflow.env.
  --move-to-downloads Move finished ZIP and DMG artifacts to ~/Downloads as a resumable stage.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --continue)
        CONTINUE_RELEASE=true
        ;;
      --move-to-downloads)
        MOVE_TO_DOWNLOADS=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

parse_notary_field() {
  local field_name="$1"
  local raw_output="$2"

  awk -F': ' -v key="$field_name" '$1 ~ key"$" {print $2; exit}' <<<"$raw_output"
}

stage_rank() {
  case "$1" in
    "new") echo 0 ;;
    "app_built") echo 10 ;;
    "dmg_built") echo 20 ;;
    "notarization_submitted") echo 30 ;;
    "notarization_accepted") echo 40 ;;
    "stapled") echo 50 ;;
    "archived") echo 60 ;;
    "exported") echo 70 ;;
    *) fail "Unknown release stage in ${STATE_PATH}: $1" ;;
  esac
}

has_reached_stage() {
  local target_stage="$1"
  [[ "$(stage_rank "$RELEASE_STAGE")" -ge "$(stage_rank "$target_stage")" ]]
}

write_state() {
  local state_tmp
  mkdir -p "$(dirname "$STATE_PATH")"
  state_tmp="$(mktemp "${STATE_PATH}.XXXXXX")"
  {
    printf 'RELEASE_STAGE=%q\n' "$RELEASE_STAGE"
    printf 'RELEASE_VARIANT=%q\n' "$RELEASE_VARIANT"
    printf 'PACKAGE_NAME=%q\n' "$PACKAGE_NAME"
    printf 'APP_BUNDLE=%q\n' "$APP_BUNDLE"
    printf 'DMG_PATH=%q\n' "$DMG_PATH"
    printf 'ZIP_PATH=%q\n' "$ZIP_PATH"
    printf 'DESTINATION_DIR=%q\n' "$DESTINATION_DIR"
    printf 'SUBMISSION_ID=%q\n' "$SUBMISSION_ID"
  } >"$state_tmp"
  mv "$state_tmp" "$STATE_PATH"
}

set_stage() {
  RELEASE_STAGE="$1"
  write_state
}

load_state() {
  local expected_release_variant="$RELEASE_VARIANT"
  local expected_package_name="$PACKAGE_NAME"
  local expected_app_bundle="$APP_BUNDLE"
  local expected_dmg_path="$DMG_PATH"
  local expected_zip_path="$ZIP_PATH"
  local requested_destination_dir="$DESTINATION_DIR"

  [[ -f "$STATE_PATH" ]] || fail "No resumable release state found at ${STATE_PATH}. Run 'make release' first."

  # shellcheck disable=SC1090
  source "$STATE_PATH"

  RELEASE_STAGE="${RELEASE_STAGE:-new}"
  SUBMISSION_ID="${SUBMISSION_ID:-}"
  DESTINATION_DIR="${DESTINATION_DIR:-$requested_destination_dir}"

  [[ "${RELEASE_VARIANT:-}" == "$expected_release_variant" ]] \
    || fail "Release state variant '${RELEASE_VARIANT:-}' does not match requested variant '${expected_release_variant}'."
  [[ "${PACKAGE_NAME:-}" == "$expected_package_name" ]] \
    || fail "Release state package '${PACKAGE_NAME:-}' does not match requested package '${expected_package_name}'."
  [[ "${APP_BUNDLE:-}" == "$expected_app_bundle" ]] \
    || fail "Release state app path '${APP_BUNDLE:-}' does not match expected path '${expected_app_bundle}'."
  [[ "${DMG_PATH:-}" == "$expected_dmg_path" ]] \
    || fail "Release state DMG path '${DMG_PATH:-}' does not match expected path '${expected_dmg_path}'."
  [[ "${ZIP_PATH:-}" == "$expected_zip_path" ]] \
    || fail "Release state ZIP path '${ZIP_PATH:-}' does not match expected path '${expected_zip_path}'."
  [[ "$DESTINATION_DIR" == "$requested_destination_dir" ]] \
    || fail "Release state destination '${DESTINATION_DIR}' does not match requested destination '${requested_destination_dir}'."
}

prepare_state() {
  if [[ "$CONTINUE_RELEASE" == true ]]; then
    load_state
    log "Resuming release from stage: ${RELEASE_STAGE}"
  else
    rm -f "$STATE_PATH"
    set_stage "new"
  fi
}

find_valid_codesign_identity() {
  local requested_identity="$1"
  local identity

  while IFS= read -r identity; do
    [[ -n "$identity" ]] || continue

    if [[ -n "$requested_identity" ]]; then
      if [[ "$identity" == "$requested_identity" ]]; then
        printf '%s\n' "$identity"
        return 0
      fi
    elif [[ "$identity" == Developer\ ID\ Application:* ]]; then
      printf '%s\n' "$identity"
      return 0
    fi
  done < <(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p'
  )

  return 1
}

codesign_identity_exists_as_certificate() {
  local identity_name="$1"
  security find-certificate -a -c "$identity_name" >/dev/null 2>&1
}

resolve_codesign_identity() {
  local requested_identity="${TYPEFLUX_CODESIGN_IDENTITY:-}"
  local resolved_identity

  resolved_identity="$(find_valid_codesign_identity "$requested_identity" || true)"
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

move_artifact() {
  local source_path="$1"
  local destination_path="${DESTINATION_DIR}/$(basename "$source_path")"

  if [[ -f "$source_path" ]]; then
    mkdir -p "$DESTINATION_DIR"
    mv -f "$source_path" "$destination_path"
    log "Moved $(basename "$source_path") to ${DESTINATION_DIR}."
    return 0
  fi

  if [[ -f "$destination_path" ]]; then
    log "$(basename "$source_path") is already in ${DESTINATION_DIR}."
    return 0
  fi

  fail "Missing release artifact: ${source_path}"
}

export_artifacts() {
  log "Moving release artifacts to ${DESTINATION_DIR}..."
  move_artifact "$DMG_PATH"
  move_artifact "$ZIP_PATH"
}

main() {
  parse_args "$@"
  require_command swift
  require_command codesign
  require_command xcrun
  require_command create-dmg
  require_env TYPEFLUX_NOTARY_PROFILE
  resolve_codesign_identity

  log "Using signing identity: ${TYPEFLUX_CODESIGN_IDENTITY}"
  log "Using notary profile: ${TYPEFLUX_NOTARY_PROFILE}"
  log "Using release variant: ${RELEASE_VARIANT}"
  log "Using package name: ${PACKAGE_NAME}"
  log "Using release state: ${STATE_PATH}"

  prepare_state

  if has_reached_stage "app_built"; then
    log "Skipping release app build; stage ${RELEASE_STAGE} already completed it."
  else
    log "Building signed release app..."
    "${ROOT_DIR}/scripts/build_release.sh"
    set_stage "app_built"
  fi

  if has_reached_stage "dmg_built"; then
    log "Skipping DMG build; stage ${RELEASE_STAGE} already completed it."
  else
    log "Building signed DMG..."
    "${ROOT_DIR}/scripts/build_dmg.sh"
    set_stage "dmg_built"
  fi

  if has_reached_stage "notarization_submitted"; then
    [[ -n "$SUBMISSION_ID" ]] || fail "Release state is missing notarization submission ID."
    log "Reusing notarization submission ID: ${SUBMISSION_ID}"
  else
    SUBMISSION_ID="$(submit_for_notarization)"
    log "Notarization submission ID: ${SUBMISSION_ID}"
    set_stage "notarization_submitted"
  fi

  if has_reached_stage "notarization_accepted"; then
    log "Skipping notarization wait; stage ${RELEASE_STAGE} already accepted submission."
  else
    wait_for_notarization "$SUBMISSION_ID"
    set_stage "notarization_accepted"
  fi

  if has_reached_stage "stapled"; then
    log "Skipping stapling; stage ${RELEASE_STAGE} already completed it."
  else
    staple_artifacts
    set_stage "stapled"
  fi

  if has_reached_stage "archived"; then
    log "Skipping ZIP refresh; stage ${RELEASE_STAGE} already completed it."
  else
    refresh_zip_archive
    set_stage "archived"
  fi

  if [[ "$MOVE_TO_DOWNLOADS" == true ]]; then
    if has_reached_stage "exported"; then
      log "Skipping artifact move; stage ${RELEASE_STAGE} already completed it."
    else
      export_artifacts
      set_stage "exported"
    fi
  fi

  log "Release workflow completed successfully."
  log "App: ${APP_BUNDLE}"
  log "ZIP: ${ZIP_PATH}"
  log "DMG: ${DMG_PATH}"
  log "State: ${STATE_PATH}"
}

main "$@"
