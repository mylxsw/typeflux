#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

COVERAGE_DIR="coverage-report"

echo "Running tests with code coverage enabled..."
python3 scripts/test_groups.py --coverage "$@"

BIN_PATH=$(swift build --show-bin-path)

# Find the .profdata file
PROFDATA="${BIN_PATH}/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
    echo "Error: Could not find $PROFDATA"
    exit 1
fi

# Find the test binary inside the xctest bundle
TEST_BINARY=$(find "${BIN_PATH}" \( -path "*/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests" -o -path "*/TypefluxTests.xctest/Contents/MacOS/TypefluxTests" \) -type f 2>/dev/null | head -1)
if [ -z "$TEST_BINARY" ]; then
    echo "Error: Could not find Typeflux test binary in .build/"
    echo "Available xctest bundles:"
    find .build -name "*.xctest" -type d
    exit 1
fi

echo "Using binary: $TEST_BINARY"
echo "Using profdata: $PROFDATA"

echo ""
echo "=== Code Coverage Report ==="
xcrun llvm-cov report \
    "$TEST_BINARY" \
    --instr-profile="$PROFDATA" \
    --ignore-filename-regex="\.build|Tests"

# Generate HTML report
mkdir -p "$COVERAGE_DIR"
xcrun llvm-cov show \
    "$TEST_BINARY" \
    --instr-profile="$PROFDATA" \
    --format=html \
    --output-dir="$COVERAGE_DIR" \
    --ignore-filename-regex="\.build|Tests"

echo ""
echo "HTML coverage report written to $COVERAGE_DIR/"
echo "Open with: open $COVERAGE_DIR/index.html"
