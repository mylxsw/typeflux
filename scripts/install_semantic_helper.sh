#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$1/SemanticSearch"
bash "$root/scripts/build_semantic_helper.sh"
mkdir -p "$destination"
cp "$root/.build/semantic/TypefluxSemanticHelper" "$destination/TypefluxSemanticHelper"
cp "$root/.build/semantic/llama.cpp/LICENSE" "$destination/llama.cpp-LICENSE.txt"
mkdir -p "$destination/licenses"
cp "$root/.build/semantic/llama.cpp/licenses/"* "$destination/licenses/"
cp "$root/.build/semantic/llama.cpp/vendor/hash/xxhash/LICENSE" "$destination/licenses/xxhash.txt"
cp "$root/.build/semantic/llama.cpp/vendor/hash/sha256/LICENSE" "$destination/licenses/sha256.txt"
cp "$root/.build/semantic/llama.cpp/vendor/hash/rotate-bits/LICENSE.md" "$destination/licenses/rotate-bits.txt"
chmod +x "$destination/TypefluxSemanticHelper"
