#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$1/TypefluxChatWindowHelper"
[[ -x "$helper" ]] || { echo "Chat window helper is missing from the build." >&2; exit 1; }
parent_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$2/Contents/Info.plist")"
[[ -n "$parent_id" ]] || { echo "Parent app identity is missing." >&2; exit 1; }
destination="$2/Contents/Helpers/TypefluxChatWindowHelper.app/Contents"
mkdir -p "$destination/MacOS"
cp "$helper" "$destination/MacOS/TypefluxChatWindowHelper"
cp "$root/app/ChatWindowHelper-Info.plist" "$destination/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $parent_id.chat-window" "$destination/Info.plist"
