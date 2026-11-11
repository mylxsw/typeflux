#!/usr/bin/env python3
"""Generate the Swift ID table from the API wire catalog; use --check in CI.

Usage: python3 scripts/generate_usage_metrics.py ../typeflux-api/internal/domain/usage_metrics.json [--check]
IDs are permanent. New metrics must use a new ID; retired IDs are never reused.
"""
import json
from pathlib import Path
import sys

entries = json.loads(Path(sys.argv[1]).read_text())
assert len({e['id'] for e in entries}) == len(entries)
assert len({e['key'] for e in entries}) == len(entries)
assert all(0 < e['id'] <= 32767 for e in entries)
path = Path(__file__).resolve().parents[1] / 'Sources/Typeflux/Analytics/UsageMetricCatalog.swift'
source = path.read_text()
start = source.index('    static let ids:')
end = source.index('    static let validIDs')
replacement = '    static let ids: [String: Int] = [\n' + ''.join(
    '        ' + json.dumps(e['key']) + ': ' + str(e['id']) + ',\n' for e in entries) + '    ]\n\n'
expected = source[:start] + replacement + source[end:]
if '--check' in sys.argv:
    assert source == expected, 'Swift catalog differs from the API contract'
    print(f'{len(entries)} stable metric IDs agree')
else:
    path.write_text(expected)
