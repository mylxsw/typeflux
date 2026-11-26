#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
fixture_output=$(mktemp -d)
trap 'rm -r -- "$fixture_output"' EXIT

# Keep the runner's inputs stable until its post-test fingerprint check finishes.
TYPEFLUX_CLASSIC_FIXTURE_OUTPUT="$fixture_output" make test \
    FILTER='ClassicCompatibilityContractTests/exportedFixturesMatchProductionWriters'
cp "$fixture_output"/* Tests/Fixtures/ClassicContract/
