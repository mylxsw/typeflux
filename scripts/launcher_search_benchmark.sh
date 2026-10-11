#!/bin/bash
set -euo pipefail
# Warm synthetic search and coordinator benchmarks, with production sources.
# No user folders are scanned. Run from any directory on macOS with Swift installed.
repo="$(cd "$(dirname "$0")/.." && pwd)"
diagnostic_dir="$(mktemp -d "${TMPDIR:-/tmp}/typeflux-search.XXXXXX")"
trap 'rm -rf "$diagnostic_dir"' EXIT
sources="$repo/Sources/Typeflux/Ask/QuickResults"

# Extract provider contracts and model/matching definitions verbatim, excluding
# disk index lifecycle, settings persistence and plugin presentation methods.
# Localization is stubbed; browser providers and feature entries are disabled.
python3 - "$sources" "$diagnostic_dir" <<'PY'
from pathlib import Path
import sys
source, output = map(Path, sys.argv[1:])
for name, folder in [('AskAppIndex', 'Apps'), ('AskFileIndex', 'Files')]:
    text = (source / folder / (name + '.swift')).read_text()
    marker = 'final class ' + name + ':'
    assert text.count(marker) == 1, f'Extraction marker changed: {name}'
    (output / (name + '.swift')).write_text(text.split(marker)[0])
for filename, marker in [
    ('Plugins/AskKeyword.swift', '/// Finds a keyword'),
    ('Plugins/System/AskSystemCommand.swift', 'struct AskSystemCommandPlugin:'),
    ('Browser/AskBrowserSearchSettings.swift', 'extension SettingsStore'),
    ('Browser/AskBrowserSearchService.swift', 'actor AskBrowserSearchService')
]:
    text = (source / filename).read_text()
    assert text.count(marker) == 1, f'Extraction marker changed: {filename}'
    (output / Path(filename).name).write_text(text.split(marker)[0])
text = (source / 'Browser/AskBrowserSearchEntry.swift').read_text()
def remove_member(text, marker):
    assert text.count(marker) == 1, f'Extraction marker changed: {marker}'
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[:start] + text[end:]
text = remove_member(text, '    func item(settings:')
text = remove_member(text, '    var item: AskPluginItem')
(output / 'AskBrowserSearchEntry.swift').write_text(text)
PY
cp "$repo/scripts/launcher_search_benchmark.swift" "$diagnostic_dir/main.swift"
swiftc -O -o "$diagnostic_dir/benchmark" \
  "$sources"/Search/*.swift \
  "$sources"/Calculator/*.swift \
  "$sources/Apps/AskAppEntry.swift" "$sources/Apps/AskAppMatcher.swift" \
  "$sources/Files/AskFileType.swift" "$sources/Files/AskFileIndexState.swift" \
  "$sources/Files/AskFileSearchCandidates.swift" \
  "$sources/Files/AskFileSearch.swift" "$sources/AskQuickResults.swift" \
  "$sources/AskQuickSearchSession.swift" "$sources/AskResultImageCache.swift" "$sources/AskFinderIcon.swift" \
  "$sources/Plugins/AskLauncherSearchEntry.swift" \
  "$diagnostic_dir"/*.swift
"$diagnostic_dir/benchmark"
