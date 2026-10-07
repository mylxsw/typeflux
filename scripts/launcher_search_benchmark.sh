#!/bin/bash
set -euo pipefail
# Warm synthetic search and coordinator benchmarks, with production sources.
# No user folders are scanned. Run from any directory on macOS with Swift installed.
repo="$(cd "$(dirname "$0")/.." && pwd)"
diagnostic_dir="$(mktemp -d "${TMPDIR:-/tmp}/typeflux-search.XXXXXX")"
trap 'rm -rf "$diagnostic_dir"' EXIT
sources="$repo/Sources/Typeflux/Ask/QuickResults"

# Reuse the actual provider contracts without the disk index lifecycle. These
# definitions are extracted verbatim; only localization is stubbed in the driver.
python3 - "$sources" "$diagnostic_dir" <<'PY'
from pathlib import Path
import sys
source, output = map(Path, sys.argv[1:])
for name, folder in [('AskAppIndex', 'Apps'), ('AskFileIndex', 'Files')]:
    text = (source / folder / (name + '.swift')).read_text()
    (output / (name + '.swift')).write_text(text.split('final class ' + name + ':')[0])
PY
cp "$repo/scripts/launcher_search_benchmark.swift" "$diagnostic_dir/main.swift"
swiftc -O -o "$diagnostic_dir/benchmark" \
  "$sources"/Search/*.swift \
  "$sources"/Calculator/*.swift \
  "$sources/Apps/AskAppEntry.swift" "$sources/Apps/AskAppMatcher.swift" \
  "$sources/Files/AskFileType.swift" "$sources/Files/AskFileIndexState.swift" \
  "$sources/Files/AskFileSearch.swift" "$sources/AskQuickResults.swift" \
  "$sources/AskQuickSearchSession.swift" \
  "$diagnostic_dir/AskAppIndex.swift" "$diagnostic_dir/AskFileIndex.swift" "$diagnostic_dir/main.swift"
"$diagnostic_dir/benchmark"
