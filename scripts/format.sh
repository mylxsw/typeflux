#!/bin/bash

set -e

echo "🎨 Running SwiftFormat..."
swiftformat . --cache .build/swiftformat.cache

echo ""
echo "🔍 Running SwiftLint..."
swiftlint lint Sources --baseline .swiftlint-baseline.json --cache-path .build/swiftlint-cache

echo ""
echo "✅ Formatting complete!"
