#!/usr/bin/env bash
set -euo pipefail
helper="$1/TypefluxMediaHelper"
[[ -x "$helper" ]] || { echo "Media helper is missing from the build." >&2; exit 1; }
mkdir -p "$2/Contents/Helpers"
cp "$helper" "$2/Contents/Helpers/TypefluxMediaHelper"
