#!/usr/bin/env bash
# One-shot cleanup script for Typeflux.
# Removes installed app bundles, persistent user data, preferences,
# caches, keychain items, TCC privacy grants, and local build artifacts.
#
# Usage:
#   scripts/uninstall.sh              # interactive (prompts before deleting)
#   scripts/uninstall.sh --yes        # non-interactive, delete everything
#   scripts/uninstall.sh --dry-run    # only print what would be removed
#   scripts/uninstall.sh --keep-build # keep project .build / coverage / DerivedData
#   scripts/uninstall.sh --reset-accessibility-history
#                                   # also reset Accessibility for all apps to
#                                   # clear stale path-based Typeflux entries
#
# Safe to run multiple times; missing targets are skipped.

set -uo pipefail

BUNDLE_ID="ai.gulu.app.typeflux"
LEGACY_BUNDLE_ID="com.typeflux"
KEYCHAIN_SERVICE="${BUNDLE_ID}.auth"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASSUME_YES=false
DRY_RUN=false
KEEP_BUILD=false
RESET_ACCESSIBILITY_HISTORY=false

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    -n|--dry-run) DRY_RUN=true ;;
    --keep-build) KEEP_BUILD=true ;;
    --reset-accessibility-history) RESET_ACCESSIBILITY_HISTORY=true ;;
    -h|--help)
      sed -n '2,15p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '  %s\n' "$*"; }
section() { printf '\n==> %s\n' "$*"; }

LSREGISTER_BIN="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

confirm() {
  $ASSUME_YES && return 0
  local prompt="$1"
  read -r -p "$prompt [y/N] " ans || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

remove_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    if $DRY_RUN; then
      log "would remove: $path"
    else
      rm -rf "$path" && log "removed: $path" || log "failed:  $path"
    fi
  fi
}

run_cmd() {
  if $DRY_RUN; then
    log "would run: $*"
  else
    log "$*"
    "$@" >/dev/null 2>&1 || true
  fi
}

unregister_bundle() {
  local path="$1"
  if [[ ! -x "$LSREGISTER_BIN" ]]; then
    return 0
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    run_cmd "$LSREGISTER_BIN" -u "$path"
  fi
}

append_path_if_missing() {
  local path="$1"
  local existing
  for existing in "${APP_PATHS[@]:-}"; do
    if [[ "$existing" == "$path" ]]; then
      return 0
    fi
  done
  APP_PATHS+=("$path")
}

APP_PATHS=(
  "/Applications/Typeflux.app"
  "$HOME/Applications/Typeflux.app"
  "$HOME/Applications/Typeflux Dev.app"
)

if [[ -n "${TYPEFLUX_DEV_APP_DIR:-}" ]]; then
  append_path_if_missing "$TYPEFLUX_DEV_APP_DIR"
fi

while IFS= read -r -d '' app_path; do
  append_path_if_missing "$app_path"
done < <(
  find "$ROOT_DIR/.build" "$ROOT_DIR/.xcode-app-derived" \
    -type d \( -name 'Typeflux.app' -o -name 'Typeflux Dev.app' \) -print0 2>/dev/null
)

while IFS= read -r -d '' app_path; do
  append_path_if_missing "$app_path"
done < <(
  find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/Build/Products/*/Typeflux.app' -print0 2>/dev/null
)

echo "Typeflux uninstaller"
echo "  bundle id:  $BUNDLE_ID"
echo "  project:    $ROOT_DIR"
$DRY_RUN && echo "  mode:       DRY RUN (no changes will be made)"
if $RESET_ACCESSIBILITY_HISTORY; then
  echo "  TCC reset:   global Accessibility history will be cleared"
fi

if ! $ASSUME_YES && ! $DRY_RUN; then
  if ! confirm "This will delete app data, preferences, caches, keychain items, and privacy grants. Continue?"; then
    echo "Aborted."
    exit 1
  fi

  if $RESET_ACCESSIBILITY_HISTORY; then
    if ! confirm "Reset Accessibility permission for ALL apps to clear stale Typeflux entries?"; then
      echo "Aborted."
      exit 1
    fi
  fi
fi

section "Quitting running Typeflux processes"
if pgrep -x Typeflux >/dev/null 2>&1; then
  run_cmd osascript -e 'tell application "Typeflux" to quit'
  sleep 1
  run_cmd pkill -x Typeflux
else
  log "no running process"
fi

section "Unregistering application bundles from LaunchServices"
for app_path in "${APP_PATHS[@]}"; do
  unregister_bundle "$app_path"
done

section "Removing application bundles"
for app_path in "${APP_PATHS[@]}"; do
  remove_path "$app_path"
done

section "Removing user data"
remove_path "$HOME/Library/Application Support/Typeflux"
remove_path "$HOME/Library/Containers/$BUNDLE_ID"
remove_path "$HOME/Library/Group Containers/$BUNDLE_ID"

section "Removing preferences"
run_cmd defaults delete "$BUNDLE_ID"
run_cmd defaults delete "$LEGACY_BUNDLE_ID"
remove_path "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
remove_path "$HOME/Library/Preferences/${LEGACY_BUNDLE_ID}.plist"

section "Removing caches and saved state"
remove_path "$HOME/Library/Caches/$BUNDLE_ID"
remove_path "$HOME/Library/HTTPStorages/$BUNDLE_ID"
remove_path "$HOME/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"
remove_path "$HOME/Library/WebKit/$BUNDLE_ID"
remove_path "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
remove_path "$HOME/Library/Logs/Typeflux"
remove_path "$HOME/Library/Logs/DiagnosticReports/Typeflux"

section "Removing Keychain items"
# Iterate until no more matching items remain.
if $DRY_RUN; then
  log "would delete keychain items for service: $KEYCHAIN_SERVICE"
else
  while security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do
    log "deleted keychain item for service: $KEYCHAIN_SERVICE"
  done
fi

section "Resetting privacy (TCC) grants"
# These remove entries from Settings > Privacy & Security for this bundle id.
for svc in Accessibility Microphone SpeechRecognition ListenEvent PostEvent AppleEvents All; do
  run_cmd tccutil reset "$svc" "$BUNDLE_ID"
done

if $RESET_ACCESSIBILITY_HISTORY; then
  section "Resetting global Accessibility history"
  # Some historical Accessibility rows are tracked by path instead of bundle id.
  # A service-wide reset is the only reliable CLI cleanup for those stale entries.
  run_cmd tccutil reset Accessibility
fi

if ! $KEEP_BUILD; then
  section "Removing project build artifacts"
  remove_path "$ROOT_DIR/.build"
  remove_path "$ROOT_DIR/.swiftpm"
  remove_path "$ROOT_DIR/coverage-report"
  remove_path "$ROOT_DIR/coverage.lcov"
  remove_path "$ROOT_DIR/Typeflux.xcodeproj"
  # Release packaging output (ignored if absent)
  while IFS= read -r -d '' f; do
    remove_path "$f"
  done < <(find "$ROOT_DIR" -maxdepth 2 \( -name 'Typeflux*.zip' -o -name 'Typeflux*.dmg' \) -print0 2>/dev/null)
  # Xcode DerivedData for this project (best-effort, name is hashed so prefix-match).
  if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
    while IFS= read -r -d '' f; do
      remove_path "$f"
    done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'Typeflux-*' -print0 2>/dev/null)
  fi
else
  section "Keeping project build artifacts (--keep-build)"
fi

section "Done"
if $DRY_RUN; then
  echo "Dry run complete. Re-run without --dry-run to actually remove the items above."
else
  echo "Typeflux has been removed. You may need to sign out of Accessibility in System Settings"
  if $RESET_ACCESSIBILITY_HISTORY; then
    echo "Accessibility permissions were reset system-wide to clear stale Typeflux history."
  else
    echo "If a stale Accessibility row remains, re-run with --reset-accessibility-history"
    echo "or remove the row manually in System Settings."
  fi
fi
