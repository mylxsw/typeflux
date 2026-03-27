#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${VOICEINPUT_DEV_APP_DIR:-$HOME/Applications/VoiceInput Dev.app}"
APP_EXEC="$APP_DIR/Contents/MacOS/VoiceInput"
LOG_PID=""

cleanup() {
  local exit_code=${1:-0}

  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill -TERM "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

swift build --package-path "$ROOT_DIR" -c debug

BIN="$ROOT_DIR/.build/debug/VoiceInput"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Keep the .app path stable to avoid macOS privacy permission re-prompts.
cp "$ROOT_DIR/app/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BIN" "$APP_DIR/Contents/MacOS/VoiceInput"

chmod +x "$APP_EXEC"

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
  codesign --force --deep --sign - --identifier "dev.voiceinput" "$APP_DIR"
fi

# If you want a fully stable identity across machines and clean TCC behavior,
# provide an explicit signing identity instead of the fallback dev signature.
# If you want signing, provide a stable identity explicitly:
#   DEV_CODESIGN_IDENTITY="Apple Development: Your Name (...)" ./scripts/run_dev_attached.sh
if [[ -n "${DEV_CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$DEV_CODESIGN_IDENTITY" "$APP_DIR"
  echo "Signed with stable identity: $DEV_CODESIGN_IDENTITY"
else
  echo "Warning: using ad-hoc signing. Accessibility permission may need to be re-granted across rebuilds."
fi

if pgrep -f "$APP_EXEC" >/dev/null 2>&1; then
  echo "VoiceInput is already running from $APP_EXEC, stopping the previous instance first..."
  pkill -f "$APP_EXEC" >/dev/null 2>&1 || true
  sleep 1
fi

echo "App launched in attached dev mode: $APP_DIR"
echo "Logs stay attached to this terminal. Press Ctrl+C to stop the app."

if command -v log >/dev/null 2>&1; then
  log stream --level debug --predicate 'process == "VoiceInput" && NOT (subsystem BEGINSWITH "com.apple.") && eventType == logEvent' &
  LOG_PID=$!
fi

if open -W -n "$APP_DIR"; then
  APP_EXIT_CODE=0
else
  APP_EXIT_CODE=$?
fi

if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
  kill -TERM "$LOG_PID" >/dev/null 2>&1 || true
  wait "$LOG_PID" >/dev/null 2>&1 || true
  LOG_PID=""
fi

exit "$APP_EXIT_CODE"
