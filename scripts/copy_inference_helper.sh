#!/usr/bin/env bash
set -euo pipefail

# Used by every SwiftPM app-bundling path; fail instead of shipping a host that
# would silently fall back to in-process inference.
binary_directory="$1"
app_bundle="$2"
helper="$binary_directory/TypefluxInferenceHelper"
[[ -x "$helper" ]] || { echo "Inference helper is missing from the build." >&2; exit 1; }
resources="$binary_directory/swift-transformers_Hub.bundle"
[[ -d "$resources" ]] || { echo "Inference tokenizer resources are missing from the build." >&2; exit 1; }
# SwiftPM's Hub resource accessor resolves relative to Bundle.main.bundleURL.
# A helper under Contents/Helpers resolves that directory, not the outer .app.
mkdir -p "$app_bundle/Contents/Helpers"
cp "$helper" "$app_bundle/Contents/Helpers/TypefluxInferenceHelper"
rm -rf "$app_bundle/Contents/Helpers/swift-transformers_Hub.bundle"
cp -R "$resources" "$app_bundle/Contents/Helpers/swift-transformers_Hub.bundle"
packaged_resources="$app_bundle/Contents/Helpers/swift-transformers_Hub.bundle"

# Older SwiftPM toolchains emit a flat resource directory. codesign only accepts
# a macOS bundle with Contents/Info.plist and its files in Contents/Resources.
if [[ ! -f "$packaged_resources/Contents/Info.plist" ]]; then
  mkdir -p "$packaged_resources/Contents/Resources"
  shopt -s dotglob nullglob
  for resource in "$packaged_resources"/*; do
    [[ "$resource" == "$packaged_resources/Contents" ]] && continue
    mv "$resource" "$packaged_resources/Contents/Resources/"
  done
  cat > "$packaged_resources/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>swift-transformers.Hub.resources</string>
  <key>CFBundleName</key><string>swift-transformers_Hub</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
fi
