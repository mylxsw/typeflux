#!/usr/bin/env python3
"""Report changed executable lines separately for the application and shared media helper."""
import argparse
import json
import gzip
import hashlib
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--lcov', required=True, type=Path)
parser.add_argument('--base', default='9021ea52fc2696965e0c8a18cbe678f766038f3f')
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
raw = gzip.decompress(args.lcov.read_bytes()).decode() if args.lcov.suffix == '.gz' else args.lcov.read_text()
for line in raw.splitlines():
    if line.startswith('SF:'):
        try:
            path = str(Path(line[3:]).resolve().relative_to(root))
        except ValueError:
            path = None
    elif path and line.startswith('DA:'):
        number, count, *_ = line[3:].split(',')
        values = coverage.setdefault(path, {})
        values[int(number)] = max(values.get(int(number), 0), int(count))
reuse = {}
previous = Path(__file__).with_name('before-final-fixes')
if (previous / 'application.lcov.gz').exists():
    fingerprints = json.loads((previous / 'final-source-fingerprints.json').read_text())
    objects = json.loads((previous / 'production-objects.json').read_text())
    prior_path = None
    for entry in gzip.decompress((previous / 'application.lcov.gz').read_bytes()).decode().splitlines():
        if entry.startswith('SF:'):
            try:
                prior_path = str(Path(entry[3:]).resolve().relative_to(root))
            except ValueError:
                prior_path = None
            if prior_path and prior_path in fingerprints and (root / prior_path).is_file():
                source_matches = hashlib.sha256((root / prior_path).read_bytes()).hexdigest() == fingerprints[prior_path]
                object_path = '.build/video-frames/arm64-apple-macosx/debug/Typeflux.build/' + Path(prior_path).name + '.o'
                obj = root / object_path
                object_matches = obj.exists() and objects.get(object_path) == hashlib.sha256(obj.read_bytes()).hexdigest()
                reuse[prior_path] = {'source_matches': source_matches, 'production_object_matches': object_matches}
                if not (source_matches and object_matches): prior_path = None
            else:
                prior_path = None
        elif prior_path and entry.startswith('DA:'):
            line, count, *_ = entry[3:].split(',')
            rows = coverage.setdefault(prior_path, {})
            rows[int(line)] = max(rows.get(int(line), 0), int(count))
Path(__file__).with_name('coverage-reuse.json').write_text(json.dumps(reuse, indent=2) + '\n')
files = {}
for path, additions in sorted(changes.items()):
    if not path.endswith('.swift'):
        continue
    values = {line: count for line, count in coverage.get(path, {}).items() if line in additions}
    covered = sum(count > 0 for count in values.values())
    files[path] = {'covered': covered, 'executable': len(values),
                   'uncovered': [line for line, count in values.items() if count == 0]}
report = {'baseline': args.base, 'denominator': 'Git added/modified executable Swift lines intersected with LLVM LCOV DA records; new Swift files included. Line coverage only, not branch coverage.', 'groups': {}, 'files': files}
helper = {"Sources/Typeflux/Ask/QuickResults/Semantic/SemanticVideoFrames.swift","Sources/Typeflux/Ask/QuickResults/Semantic/SemanticAudioWindows.swift",
          "Sources/Typeflux/Ask/QuickResults/Semantic/SemanticMediaExtractor.swift"}
for group in ['application', 'filesystem_helper', 'native_media_runtime']:
    rows = [row for path, row in files.items()
            if ((group == 'filesystem_helper' and path in helper)
                or (group == 'application' and path.startswith('Sources/Typeflux/') and path not in helper)
                or (group == 'native_media_runtime' and path.startswith('Sources/TypefluxMedia'))) ]
    covered = sum(row['covered'] for row in rows)
    total = sum(row['executable'] for row in rows)
    report['groups'][group] = {'covered': covered, 'executable': total,
                              'percent': round(100 * covered / total, 2) if total else None}
Path(__file__).with_name('changed-coverage.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report['groups']))
