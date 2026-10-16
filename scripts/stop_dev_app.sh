#!/usr/bin/env bash
set -euo pipefail

app_dir="${1:?Pass the development app path}"
app_exec="$app_dir/Contents/MacOS/Typeflux"

if ! pgrep -f "^${app_exec}$" >/dev/null 2>&1; then
  exit 0
fi

# A normal quit lets the storage modules record a clean stop. Killing the process
# leaves their crash-protection budget spent and eventually blocks local history.
swift - "$app_exec" <<'SWIFT'
import AppKit

let executable = CommandLine.arguments[1]
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.path == executable }) else {
    exit(0)
}
guard app.terminate() else {
    fputs("Error: Typeflux did not accept a normal quit request.\n", stderr)
    exit(1)
}
SWIFT

for ((attempt = 0; attempt < 60; attempt++)); do
  if ! pgrep -f "^${app_exec}$" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.5
done

echo "Error: Typeflux did not quit cleanly. Close $app_dir and retry." >&2
exit 1
