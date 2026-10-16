#!/bin/bash
set -euo pipefail
export TYPEFLUX_TEST_FILES="$(cat "$TYPEFLUX_RANKING_TEST_FILES")"
operation="$1"
shift
if [[ "$operation" == test && " $* " == *" list "* ]]; then
    /usr/bin/swift build --build-system native --scratch-path "$TYPEFLUX_COVERAGE_SCRATCH" --build-tests --enable-code-coverage --jobs 4 >&2
    coverage_bin=$(/usr/bin/swift build --build-system native --scratch-path "$TYPEFLUX_COVERAGE_SCRATCH" --show-bin-path)
    xcrun llvm-objdump --section-headers "$coverage_bin/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests" | /usr/bin/grep -q __llvm_covmap
    exec /usr/bin/swift test --build-system native --scratch-path "$TYPEFLUX_COVERAGE_SCRATCH" --skip-build "$@"
fi
case "$operation" in
    build|test) exec /usr/bin/swift "$operation" --build-system native --scratch-path "$TYPEFLUX_COVERAGE_SCRATCH" "$@" ;;
    *) exec /usr/bin/swift "$operation" "$@" ;;
esac
