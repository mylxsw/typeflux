"""Verify source stability and retain actual products, rows and owned profile observations."""
from collections import defaultdict
import csv
import gzip
import hashlib
import json
import math
from pathlib import Path

ROOT = Path.cwd()
OUT = Path(__file__).resolve().parent


def item(path):
    return {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


freeze = json.loads((OUT / 'source-freeze.json').read_text())
for name, expected in freeze['files'].items():
    assert item(ROOT / name)['sha256'] == expected, name

native = json.loads((OUT / 'native-ui.json').read_text())
assert native['complete'] and native['stage'] == 'complete' and len(native['rows']) == 12
groups = defaultdict(list)
for row in native['rows']:
    assert row['icon_refresh']['result_identities_preserved'] and row['icon_refresh']['target_still_in_ax']
    assert row['icon_refresh']['after_revision'] > row['icon_refresh']['before_revision']
    assert row['requested_launcher_width'] == 1500
    assert row['launcher_width'] == min(1500, row['screen_visible_width'] - 24)
    assert row['group'] != 'cross_language' or not row['target_in_fts']
    groups[row['entry'], row['group']].append(row)


def quantiles(values):
    values = sorted(values)
    return {str(p): values[math.ceil((len(values) - 1) * p)] for p in [.5, .95, .99, 1]}


summary = []
for (entry, group), rows in sorted(groups.items()):
    assert len(rows) == 3
    summary.append({'entry': entry, 'group': group, 'n': len(rows),
                    **{key: quantiles([row[key] for row in rows])
                       for key in ['publication_ms', 'layout_ax_ms', 'complete_query_ms']}})
with (OUT / 'native-ui.csv').open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=[key for key in native['rows'][0] if key != 'icon_refresh'],
                            extrasaction='ignore', lineterminator='\n')
    writer.writeheader(); writer.writerows(native['rows'])

binaries = ['.build/out/Products/Release/Typeflux',
            '.build/out/Products/Release/TypefluxFocusedTests.xctest/Contents/MacOS/TypefluxFocusedTests',
            '.build/semantic/TypefluxSemanticHelper', '.build/semantic/embeddinggemma-2-Q8_0.gguf',
            '.build/candidate/Typeflux.app/Contents/MacOS/Typeflux']
objects = {str(path.relative_to(ROOT)): item(path) for path in (ROOT / '.build/out').rglob('*.o')
           if '/Typeflux.build/' in str(path) or '/TypefluxFocusedTests.build/' in str(path)}
profiles = {}
for path in sorted((ROOT / '.build').glob('ui-drift-helper-*.profraw')):
    profiles[path.name] = item(path)
    if path.stat().st_size:
        folder = OUT / 'raw-profiles'; folder.mkdir(exist_ok=True)
        (folder / (path.name + '.gz')).write_bytes(gzip.compress(path.read_bytes(), mtime=0))
(OUT / 'binary-profile.json').write_text(json.dumps({
    'source_commit': freeze['source_commit'], 'binaries': {name: item(ROOT / name) for name in binaries},
    'objects': objects, 'profiles': profiles,
    'boundary': 'Current Release app/test/library and signed app candidate; reused accepted native helper/model. Zero-byte profiles remain observations, no new product coverage percentage.'}, indent=2) + '\n')
(OUT / 'native-summary.json').write_text(json.dumps({
    'groups': summary, 'rows': 12, 'missing': 0, 'icon_refresh_preserved': 12,
    'geometry': [{key: row[key] for key in ['entry', 'launcher_width', 'requested_launcher_width', 'screen_visible_width']}
                 for row in native['rows'][::6]],
    'mutation': native['mutation'],
    'boundary': 'Three observations per entry/group; empirical p95/p99 equal the maximum and cannot estimate production tails. Input commit to publication/layout/AX and complete query separately. Icon refresh checks occur after the timed query.'}, indent=2) + '\n')
print(json.dumps({'groups': summary, 'objects': len(objects), 'profile_observations': len(profiles),
                  'nonempty_profiles': sum(row['bytes'] > 0 for row in profiles.values())}))
