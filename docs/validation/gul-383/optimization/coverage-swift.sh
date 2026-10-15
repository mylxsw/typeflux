#!/bin/bash
# Task-local shim: install as .build/coverage-bin/swift and prepend that directory to PATH.
# Swift 6.4's test discovery build otherwise removes coverage instrumentation here.
set -euo pipefail
operation="$1"
shift
if [[ "$operation" == test && " $* " == *" list "* ]]; then
    /usr/bin/swift build --build-system native --scratch-path "${TYPEFLUX_COVERAGE_SCRATCH:?}" --build-tests --enable-code-coverage
    coverage_bin=$(/usr/bin/swift build --build-system native --scratch-path "$TYPEFLUX_COVERAGE_SCRATCH" --show-bin-path)
    xcrun llvm-objdump --section-headers "$coverage_bin/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests" | /usr/bin/grep -q __llvm_covmap
    exec /usr/bin/swift test --build-system native --scratch-path "$TYPEFLUX_COVERAGE_SCRATCH" --skip-build "$@"
fi
case "$operation" in
    build|test) exec /usr/bin/swift "$operation" --build-system native --scratch-path "${TYPEFLUX_COVERAGE_SCRATCH:?}" "$@" ;;
    *) exec /usr/bin/swift "$operation" "$@" ;;
esac
