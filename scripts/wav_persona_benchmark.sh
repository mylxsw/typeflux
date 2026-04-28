#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Match the packaged app identity so command-line runs can read the same
# UserDefaults domain and Keychain auth service as Typeflux.app.
export TYPEFLUX_BUNDLE_IDENTIFIER="${TYPEFLUX_BUNDLE_IDENTIFIER:-ai.gulu.app.typeflux}"
export TYPEFLUX_USER_DEFAULTS_SUITE="${TYPEFLUX_USER_DEFAULTS_SUITE:-ai.gulu.app.typeflux}"

swift run --package-path "$ROOT_DIR" Typeflux batch-wav "$@"
