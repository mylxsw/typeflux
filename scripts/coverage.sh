#!/bin/bash
set -e

COVERAGE_DIR="coverage-report"

echo "Running tests with code coverage enabled..."
swift test --enable-code-coverage

BIN_PATH=$(swift build --show-bin-path)

# Find the .profdata file
PROFDATA=$(find .build -name "default.profdata" -type f 2>/dev/null | head -1)
if [ -z "$PROFDATA" ]; then
    echo "Error: Could not find .profdata file in .build/"
    exit 1
fi

# Find the test binary inside the xctest bundle
TEST_BINARY=$(find "${BIN_PATH}" -path "*/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests" -type f 2>/dev/null | head -1)
if [ -z "$TEST_BINARY" ]; then
    echo "Error: Could not find TypefluxPackageTests binary in .build/"
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
