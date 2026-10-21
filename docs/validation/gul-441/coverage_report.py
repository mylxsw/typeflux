#!/usr/bin/env python3
"""Join only LCOV records whose whole-source SHA-256 matches the reviewed source.

Run from the repository root. Produces portable relative paths and the exact
changed executable-line denominator. Old source versions never add coverage.
"""
from pathlib import Path
import argparse
import gzip
import hashlib
import json
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base', default='aeda1f98e294e9f24406c3e0b1402a5570c1f9b7')
args = parser.parse_args()
output = Path(__file__).resolve().parent
records, used, hashes, counts = [], {}, {}, {}
for manifest in sorted(output.glob('*-source-hashes.json')):
    name = manifest.name.removesuffix('-source-hashes.json')
    source = output / (name + '.lcov.gz')
    if not source.exists():
        continue
    recorded = json.loads(manifest.read_text())
    kept = []
    for record in gzip.decompress(source.read_bytes()).decode().split('end_of_record\n'):
        filename = next((row[3:] for row in record.splitlines() if row.startswith('SF:')), None)
        if not filename:
            continue
        if '/Sources/Typeflux/' in filename:
            filename = 'Sources/Typeflux/' + filename.split('/Sources/Typeflux/', 1)[1]
        path = Path(filename)
        if not path.exists() or recorded.get(filename) != hashlib.sha256(path.read_bytes()).hexdigest():
            continue
        kept.append(filename)
        hashes[filename] = recorded[filename]
        rows = []
        for row in record.splitlines():
            if row.startswith('SF:'):
                row = 'SF:' + filename
            elif row.startswith('DA:'):
                line, hits, *_ = row[3:].split(',')
                key = filename, int(line)
                counts[key] = max(counts.get(key, 0), int(hits))
            rows.append(row)
        records.append('\n'.join(rows) + '\nend_of_record\n')
    used[name] = kept
with gzip.open(output / 'matching-source.lcov.gz', 'wb') as stream:
    stream.write(''.join(records).encode())
changed = set()
filename = None
line = 0
diff = subprocess.check_output(['git', 'diff', '--unified=0', args.base, '--', 'Sources/Typeflux'], text=True)
for row in diff.splitlines():
    if row.startswith('+++ b/'):
        filename = row[6:]
    elif row.startswith('@@'):
        line = int(re.search(r'\+(\d+)', row).group(1))
    elif row.startswith('+'):
        if filename and filename.endswith('.swift'):
            changed.add((filename, line))
        line += 1
    elif not row.startswith('-') and not row.startswith('\\'):
        line += 1
files = {}
for filename in sorted({path for path, _ in changed}):
    measured = sorted(line for path, line in changed if path == filename and (path, line) in counts)
    covered = [line for line in measured if counts[filename, line] > 0]
    files[filename] = dict(executable_lines=measured, covered_lines=covered,
                           uncovered_lines=sorted(set(measured) - set(covered)),
                           source_sha256=hashlib.sha256(Path(filename).read_bytes()).hexdigest())
covered = sum(len(file['covered_lines']) for file in files.values())
total = sum(len(file['executable_lines']) for file in files.values())
report = dict(base=args.base, covered=covered, total=total, percentage=100 * covered / total,
              files=files, included_records=used)
(output / 'changed-coverage.json').write_text(json.dumps(report, indent=2) + '\n')
for filename, file in files.items():
    print(f"{filename}: {len(file['covered_lines'])}/{len(file['executable_lines'])}; uncovered {file['uncovered_lines']}")
print(f'TOTAL: {covered}/{total} ({100 * covered / total:.2f}%)')
if covered / total <= .8:
    raise SystemExit('Changed executable-line coverage must exceed 80%')
