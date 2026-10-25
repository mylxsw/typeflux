#!/usr/bin/env bash
set -euo pipefail

app_dir="${1:?Pass the development app path}"
app_exec="$app_dir/Contents/MacOS/Typeflux"
# pgrep uses extended regular expressions, not literal paths.
executable_pattern="$(python3 -c 'import re, sys; print(re.escape(sys.argv[1]))' "$app_exec")"
host_pattern="^${executable_pattern}$"
process_pattern="^${executable_pattern}( --feature-process [a-zA-Z]+ --ipc-fd 100)?$"

if ! pgrep -f "$process_pattern" >/dev/null 2>&1; then
  exit 0
fi

request_quit() {
host_pids=()
while IFS= read -r pid; do
  [[ -n "$pid" ]] && host_pids+=("$pid")
done < <(pgrep -f "$host_pattern" || true)

# A normal quit lets the storage modules record a clean stop. Killing the process
# leaves their crash-protection budget spent and eventually blocks local history.
# Feature processes share the executable path, so select the exact host PIDs
# instead of the first NSWorkspace entry with that path.
if [[ ${#host_pids[@]} -gt 0 ]]; then
  swift - "$app_exec" "${host_pids[@]}" <<'SWIFT'
import AppKit

let executable = CommandLine.arguments[1]
for argument in CommandLine.arguments.dropFirst(2) {
    guard let pid = Int32(argument),
          let app = NSRunningApplication(processIdentifier: pid),
          !app.isTerminated else { continue }
    guard app.executableURL?.path == executable else {
        fputs("Error: Typeflux process identity changed; refusing to quit PID \(argument).\n", stderr)
        exit(1)
    }
    guard app.terminate() || app.isTerminated else {
        fputs("Error: Typeflux did not accept a normal quit request (PID \(argument)).\n", stderr)
        exit(1)
    }
}
SWIFT
fi

}

request_quit

# Child shutdown alone can take 30 seconds, followed by the host's own storage
# cleanup. Also wait for feature children before replacing their executable.
echo "Waiting for Typeflux to finish saving and exit (up to 120 seconds)..."
for ((attempt = 0; attempt < 240; attempt++)); do
  if ! pgrep -f "$process_pattern" >/dev/null 2>&1; then
    exit 0
  fi
  # AppKit may cancel a quit while a feature is finishing a recording or
  # draining helpers. Reissue a normal quit; never bypass its save checks.
  if (( attempt > 0 && attempt % 20 == 0 )); then
    request_quit
  fi
  sleep 0.5
done

echo "Error: Typeflux did not quit cleanly. Close $app_dir and retry." >&2
echo "Processes still running (PID and command):" >&2
pgrep -fl "$process_pattern" >&2 || true
exit 1
