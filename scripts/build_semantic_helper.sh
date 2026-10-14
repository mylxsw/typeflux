#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the optional arm64 runtime outside the macOS 13 / universal SwiftPM target.
revision=4d756bc72bf00a4aacf410ae15a2d315f3db400d
root="$PWD/.build/semantic"
cmake_bin="${TYPEFLUX_CMAKE:-cmake}"
mkdir -p "$root"
if [[ ! -d "$root/llama.cpp/.git" ]]; then
    git clone --depth 1 --branch b11461 https://github.com/ggml-org/llama.cpp.git "$root/llama.cpp"
fi
[[ "$(git -C "$root/llama.cpp" rev-parse HEAD)" == "$revision" ]] || { echo 'Unexpected llama.cpp revision' >&2; exit 1; }
if git -C "$root/llama.cpp" apply --check "$PWD/scripts/semantic-no-logits.patch" 2>/dev/null; then
    git -C "$root/llama.cpp" apply "$PWD/scripts/semantic-no-logits.patch"
else
    git -C "$root/llama.cpp" apply --reverse --check "$PWD/scripts/semantic-no-logits.patch"
fi
expected_diff=$'1\t1\tsrc/llama-context.cpp'
[[ "$(git -C "$root/llama.cpp" diff --numstat)" == "$expected_diff" ]] || {
    echo 'Unexpected local changes in pinned llama.cpp sources' >&2; exit 1;
}
git -C "$root/llama.cpp" diff --cached --quiet
"$cmake_bin" -S "$root/llama.cpp" -B "$root/native" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF \
    -DLLAMA_BUILD_MTMD=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF
"$cmake_bin" --build "$root/native" --target llama -j 4
mkdir -p "$root/include" "$root/lib"
cp "$root/llama.cpp/include/llama.h" "$root/include/"
cp "$root/llama.cpp/ggml/include/"*.h "$root/include/"
cat > "$root/include/module.modulemap" <<'MAP'
module CLlama [system] {
    header "llama.h"
    link "llamacpp"
    link "c++"
    link framework "Accelerate"
    link framework "Foundation"
    link framework "Metal"
    link framework "MetalKit"
    export *
}
MAP
libraries=(
    "$root/native/src/libllama.a"
    "$root/native/ggml/src/libggml.a"
    "$root/native/ggml/src/libggml-base.a"
    "$root/native/ggml/src/libggml-cpu.a"
    "$root/native/ggml/src/ggml-metal/libggml-metal.a"
    "$root/native/ggml/src/ggml-blas/libggml-blas.a"
)
libtool -static -o "$root/lib/libllamacpp.a" "${libraries[@]}"
swiftc -O -target arm64-apple-macos14.0 -I "$root/include" -L "$root/lib" \
    Sources/TypefluxSemanticHelper/main.swift -o "$root/TypefluxSemanticHelper"
echo "$root/TypefluxSemanticHelper"
