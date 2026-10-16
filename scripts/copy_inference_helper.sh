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
