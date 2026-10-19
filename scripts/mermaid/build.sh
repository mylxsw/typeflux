#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root/scripts/mermaid"
npm ci --no-audit --no-fund
./node_modules/.bin/esbuild entry.js \
  --bundle --minify --format=iife --target=safari16 \
  --legal-comments=external \
  --outfile="$project_root/Sources/Typeflux/Resources/mermaid.bundle.js"
node notices.mjs
