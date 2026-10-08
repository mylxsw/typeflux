#!/usr/bin/env bash
set -euo pipefail

binary_dir="${1:?Expected Swift build output directory}"
resource_dir="${2:?Expected app resource directory}"
bundles=(Typeflux_Typeflux.bundle TypefluxChat_TypefluxChat.bundle)

# Validate first so a missing package cannot produce an app that crashes at launch.
for bundle in "${bundles[@]}"; do
  if [[ ! -d "$binary_dir/$bundle" ]]; then
    echo "Missing resource bundle: $binary_dir/$bundle" >&2
    exit 1
  fi
done
mkdir -p "$resource_dir"
for bundle in "${bundles[@]}"; do
  rm -rf "$resource_dir/$bundle"
  cp -R "$binary_dir/$bundle" "$resource_dir/$bundle"
done
