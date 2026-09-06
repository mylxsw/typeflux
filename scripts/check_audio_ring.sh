#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_output="$(mktemp -d "${TMPDIR:-/tmp}/typeflux-audio-ring.XXXXXX")"
trap 'rm -rf "$task_output"' EXIT

for sanitizer in address,undefined thread; do
    xcrun clang -std=c11 -g "-fsanitize=$sanitizer" \
        -I "$task_root/Sources/TypefluxAudioSafety/include" \
        "$task_root/Tests/AudioCapture/hal_ring_stress.c" \
        "$task_root/Sources/TypefluxAudioSafety/TFHALInput.c" \
        -framework AudioToolbox -framework CoreAudio -framework CoreServices \
        -o "$task_output/check"
    "$task_output/check"
done
