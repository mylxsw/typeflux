#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  A|a|sculpted) icon_style=sculpted ;;
  B|b|light) icon_style=light ;;
  *) echo "Usage: $0 A|B [path/to/Typeflux.app]" >&2; exit 2 ;;
esac
app_path="${2:-$HOME/Applications/Typeflux Dev.app}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Contents/Info.plist")"
# Stop before changing defaults so an exiting process cannot restore the old preference.
bash "$repo_root/scripts/stop_dev_app.sh" "$app_path"
defaults write "$bundle_id" launcherFeatureIconStyle -string "$icon_style"
open "$app_path"
echo "Launcher icon family: $icon_style (no rebuild required)"
