#!/bin/bash

set -e

echo "🎨 Running SwiftFormat..."
swiftformat .

echo ""
echo "🔍 Running SwiftLint..."
swiftlint lint Sources

echo ""
echo "✅ Formatting complete!"

