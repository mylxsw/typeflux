#!/bin/bash
set -euo pipefail

# Called before signing by both dev launchers; do not change the stable bundle
# identifier or native OAuth/billing schemes used by existing installations.
plist="$1"
channel="${TYPEFLUX_WEB_AUTH_CHANNEL:-development}"
case "$channel" in
  development|production) ;;
  *) echo "Error: TYPEFLUX_WEB_AUTH_CHANNEL must be development or production." >&2; exit 1 ;;
esac
/usr/libexec/PlistBuddy -c "Set :TYPEFLUX_WEB_AUTH_CHANNEL $channel" "$plist"
if [[ "$channel" == development ]]; then
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:2 dict' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:2:CFBundleURLName string ai.gulu.app.typeflux.dev.auth' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:2:CFBundleURLSchemes array' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string ai.gulu.app.typeflux.dev' "$plist"
fi
for key in TYPEFLUX_WEB_AUTH_ORIGIN TYPEFLUX_WEB_AUTH_API_ORIGIN; do
  if [[ -n "${!key:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$key string ${!key}" "$plist"
  fi
done
