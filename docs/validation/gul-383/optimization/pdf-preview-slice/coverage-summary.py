#!/usr/bin/env python3
"""Report changed executable lines separately for the application and shared media helper."""
import argparse
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--lcov', required=True, type=Path)
parser.add_argument('--base', default='ebf516a7')
args = parser.parse_args()
root = Path.cwd().resolve()
changes = {}
path = None
for line in subprocess.check_output(['git', 'diff', '--unified=0', args.base, '--', 'Sources'], text=True).splitlines():
    if line.startswith('+++ b/'):
        path = line[6:]
        changes.setdefault(path, set())
    elif path and (match := re.match(r'@@ .*\+(\d+)(?:,(\d+))? @@', line)):
        start, count = int(match[1]), int(match[2] or 1)
        changes[path].update(range(start, start + count))
for path in subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], text=True).splitlines():
    if path.startswith('Sources/') and path.endswith('.swift'):
        changes[path] = set(range(1, len(Path(path).read_text().splitlines()) + 1))
coverage = {}
path = None
for line in args.lcov.read_text().splitlines():
    if line.startswith('SF:'):
        try:
            path = str(Path(line[3:]).resolve().relative_to(root))
        except ValueError:
            path = None
    elif path and line.startswith('DA:'):
        number, count, *_ = line[3:].split(',')
        values = coverage.setdefault(path, {})
        values[int(number)] = max(values.get(int(number), 0), int(count))
files = {}
for path, additions in sorted(changes.items()):
    if not path.endswith('.swift'):
        continue
    values = {line: count for line, count in coverage.get(path, {}).items() if line in additions}
    covered = sum(count > 0 for count in values.values())
    files[path] = {'covered': covered, 'executable': len(values),
                   'uncovered': [line for line, count in values.items() if count == 0]}
report = {'baseline': args.base, 'denominator': 'Git added/modified executable Swift lines intersected with LLVM LCOV DA records; new Swift files included. Line coverage only, not branch coverage.', 'groups': {}, 'files': files}
for group, prefix in [('application', 'Sources/Typeflux/'), ('shared_media', 'Sources/TypefluxMedia')]:
    rows = [row for path, row in files.items() if path.startswith(prefix)]
    covered = sum(row['covered'] for row in rows)
    total = sum(row['executable'] for row in rows)
    report['groups'][group] = {'covered': covered, 'executable': total,
                              'percent': round(100 * covered / total, 2) if total else None}
Path(__file__).with_name('changed-coverage.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report['groups']))
