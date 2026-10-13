#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
python3 scripts/check_ui_literals.py "$@"
swiftlint lint Sources --strict --baseline .swiftlint-baseline.json --no-cache
