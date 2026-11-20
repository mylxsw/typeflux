#!/bin/bash
# Remove Typeflux for the current macOS user, including local workspaces and credentials.
# Usage: uninstall.sh [--yes] [--dry-run] [--keep-build]
# A standalone copy only cleans the installation. Inside the Typeflux source tree,
# --keep-build preserves SwiftPM and Xcode build products.
set -o pipefail
shopt -s nullglob

bundle_id=ai.gulu.app.typeflux
helper_id="$bundle_id.chat-window"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
yes=false
dry_run=false
keep_build=false
errors=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) yes=true ;;
    -n|--dry-run) dry_run=true ;;
    --keep-build) keep_build=true ;;
    -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

fail() { printf 'ERROR: %s\n' "$*" >&2; errors=$((errors + 1)); }
remove_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  if $dry_run; then
    echo "Would remove: $path"
  elif rm -rf -- "$path" && [[ ! -e "$path" && ! -L "$path" ]]; then
    echo "Removed: $path"
  else
    fail "Could not remove $path"
  fi
}

# Never infer a developer checkout from the parent of a copied desktop tool.
script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
project="${script_dir%/*}"
if [[ "$script_dir" != */scripts || ! -f "$project/Package.swift" ||
      ! -f "$project/Sources/Typeflux/App/TypefluxDataDirectories.swift" ]]; then
  keep_build=true
fi

if [[ "$(uname -s)" != Darwin || "$EUID" == 0 || "$HOME" != /* || "$HOME" == / ]]; then
  echo "Run as the macOS user whose Typeflux installation you want to remove." >&2
  exit 1
fi
echo "Typeflux cleanup for $(id -un) on $(hostname)"
if $dry_run; then
  echo "Preview only."
elif ! $yes; then
  read -r -p "Permanently delete Typeflux, local chats, workspaces, credentials and privacy grants? [y/N] " answer
  [[ "$answer" == [yY] ]] || exit 1
fi

# Include the host, its feature children and separately named helper executables.
process_ids() {
  ps -U "$(id -un)" -o pid=,comm= | awk '{
    pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
    if ($0 ~ /(^|\/)Typeflux(ChatWindowHelper|InferenceHelper|MediaHelper|SemanticHelper)?$/) print pid
  }'
}
pids="$(process_ids)" || exit 1
if [[ -n "$pids" ]]; then
  if $dry_run; then
    echo "Would stop Typeflux processes: $pids"
  else
    while IFS= read -r pid; do kill -TERM "$pid" 2>/dev/null || :; done <<< "$pids"
    for ((i=0; i<60; i++)); do
      pids="$(process_ids)" || exit 1
      [[ -z "$pids" ]] && break
      sleep 0.5
    done
    if [[ -n "$pids" ]]; then
      echo "Typeflux is still running (PIDs: $pids). Quit it and retry." >&2
      exit 1
    fi
  fi
fi

# Only unregister/delete real Typeflux bundles, even when a custom path is set.
apps=()
add_app() {
  local path="$1" identifier existing
  [[ -e "$path" || -L "$path" ]] || return 0
  identifier="$(plutil -extract CFBundleIdentifier raw -o - "$path/Contents/Info.plist" 2>/dev/null)"
  case "$identifier" in "$bundle_id"|com.typeflux) ;; *) fail "Unrecognized application at $path"; return ;; esac
  for existing in "${apps[@]}"; do [[ "$existing" == "$path" ]] && return 0; done
  apps+=("$path")
}
for base in /Applications "$HOME/Applications"; do
  for path in "$base/Typeflux.app" "$base/Typeflux Dev.app"; do
    add_app "$path"
    for backup in "$path".typeflux-backup.[0-9]*; do add_app "$backup"; done
  done
done
if [[ -n "${TYPEFLUX_DEV_APP_DIR:-}" ]]; then
  case "$TYPEFLUX_DEV_APP_DIR" in /*.app) add_app "$TYPEFLUX_DEV_APP_DIR" ;; *) fail "Expected an absolute .app path" ;; esac
fi
if ! $keep_build; then
  for base in "$project/.build" "$project/.xcode-app-derived"; do
    [[ -d "$base" && ! -L "$base" ]] || continue
    while IFS= read -r -d '' path; do add_app "$path"; done < <(
      find "$base" -type d \( -name Typeflux.app -o -name 'Typeflux Dev.app' \) -prune -print0
    )
  done
fi

# Reset while LaunchServices can still resolve the app. A second run after
# removal can legitimately report that the bundle identifier is unknown.
for domain in "$bundle_id" "$helper_id" com.typeflux; do
  if $dry_run; then
    echo "Would reset privacy grants for $domain"
  elif message="$(LC_ALL=C tccutil reset All "$domain" 2>&1)"; then
    echo "Reset privacy grants for $domain"
  elif [[ "$message" == *"No such bundle identifier"* ]]; then
    echo "No registered bundle for privacy reset: $domain"
  else
    fail "$message"
  fi
done
for path in "${apps[@]}"; do
  if ! $dry_run; then
    "$lsregister" -u "$path" || fail "Could not unregister $path"
  fi
  remove_path "$path"
done

library="$HOME/Library"
remove_path "$HOME/.typeflux"
remove_path "$library/Application Support/Typeflux"
remove_path "$library/Caches/Typeflux"
# Only Workspaces belonged to the legacy layout; other documents may be user exports.
documents="$HOME/Documents/Typeflux"
if [[ -L "$documents" ]]; then
  echo "Preserved linked documents folder: $documents"
elif [[ -d "$documents" ]]; then
  remove_path "$documents/Workspaces"
  if ! $dry_run; then rmdir "$documents" 2>/dev/null || :; fi
fi
for domain in "$bundle_id" "$helper_id" com.typeflux; do
  if $dry_run; then
    echo "Would clear preferences for $domain"
  elif defaults read "$domain" >/dev/null 2>&1; then
    defaults delete "$domain" || fail "Could not clear preferences for $domain"
  fi
  for path in "$library/Preferences/$domain.plist" "$library/Preferences/ByHost/$domain".*.plist \
    "$library/Containers/$domain" "$library/Group Containers/$domain" \
    "$library/Application Scripts/$domain" "$library/Application Support/$domain" \
    "$library/Caches/$domain" "$library/Caches/com.apple.nsurlsessiond/Downloads/$domain" \
    "$library/HTTPStorages/$domain" "$library/HTTPStorages/$domain.binarycookies" \
    "$library/Cookies/$domain.binarycookies" "$library/WebKit/$domain" \
    "$library/Saved Application State/$domain.savedState" \
    "$library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$domain".sfl*; do
    remove_path "$path"
  done
done
remove_path "$library/Logs/Typeflux"
for name in Typeflux TypefluxChatWindowHelper TypefluxInferenceHelper TypefluxMediaHelper TypefluxSemanticHelper; do
  remove_path "$library/Logs/DiagnosticReports/$name"
  for dir in "$library/Logs/DiagnosticReports" "$library/Logs/DiagnosticReports/Retired"; do
    for path in "$dir/$name"[-_]*.{ips,crash}; do remove_path "$path"; done
  done
done

temp_dir="$(getconf DARWIN_USER_TEMP_DIR)" || exit 1
cache_dir="$(getconf DARWIN_USER_CACHE_DIR)" || exit 1
[[ -n "$temp_dir" && -n "$cache_dir" ]] || exit 1
for domain in "$bundle_id" "$helper_id"; do
  remove_path "$temp_dir/$domain"
  remove_path "$cache_dir/$domain"
done
for path in "$temp_dir"/{TypefluxLivePreview,typeflux-low-energy-retry,typeflux-transcoded,typeflux-ollama.log,typeflux-workflow-preview} \
  "$temp_dir"/typeflux-{playback,clipboard-drag,feedback,update,follow-up,inference,media,capture-check}-* "$temp_dir"/typeflux_relaunch_*.sh \
  /tmp/typeflux-ipc-*; do
  [[ -O "$path" ]] && remove_path "$path"
done

services=("$bundle_id.auth" "$bundle_id.auth.v1" "$bundle_id.auth.v2" "$bundle_id.google-cloud-speech"
  dev.typeflux.auth debug.typeflux.auth debug.typeflux.auth3 com.typeflux.mcp.oauth
  com.typeflux.ask.search com.typeflux.ask.image-generation)
for service in "${services[@]}"; do
  if $dry_run; then
    echo "Would clear Keychain service: $service"
    continue
  fi
  while :; do
    # Multiple accounts can use one service. Only errSecItemNotFound (44)
    # confirms that there are no matching items left in the search list.
    security delete-generic-password -s "$service" >/dev/null 2>&1
    status=$?
    case "$status" in
      0) echo "Removed Keychain item for $service" ;;
      44) break ;;
      *) fail "Keychain service $service returned $status"; break ;;
    esac
  done
done

if ! $keep_build; then
  for path in "$project"/{.build,.swiftpm,.xcode-app-derived,.xcode-derived,coverage-report,coverage.lcov,default.profraw} \
    "$library/Developer/Xcode/DerivedData"/{Typeflux,TypefluxApp}-*; do remove_path "$path"; done
fi
if ((errors)); then
  echo "Cleanup incomplete ($errors errors). Review the messages above and retry." >&2
  exit 1
fi
if $dry_run; then echo "Preview complete."; else echo "Typeflux cleanup complete."; fi
