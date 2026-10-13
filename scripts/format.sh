#!/bin/bash

set -euo pipefail

echo "🎨 Running SwiftFormat..."
swiftformat . --cache .build/swiftformat.cache

echo ""
echo "🛠️ Running SwiftLint autocorrect..."
swiftlint --fix Sources --baseline .swiftlint-baseline.json --cache-path .build/swiftlint-cache

echo ""
echo "🎨 Normalizing autocorrected Swift with SwiftFormat..."
swiftformat . --cache .build/swiftformat.cache

echo ""
echo "🔍 Running SwiftLint..."
python3 scripts/check_ui_literals.py
swiftlint lint Sources --strict --baseline .swiftlint-baseline.json --cache-path .build/swiftlint-cache

echo ""
echo "✅ Formatting complete!"
