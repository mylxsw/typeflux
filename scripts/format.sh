#!/bin/bash

set -e

echo "🎨 Running SwiftFormat..."
swiftformat .

echo ""
echo "🔍 Running SwiftLint..."
swiftlint lint Sources --baseline .swiftlint-baseline.json

echo ""
echo "✅ Formatting complete!"
