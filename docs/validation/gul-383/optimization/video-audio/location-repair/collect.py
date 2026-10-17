#!/usr/bin/env python3
"""Keep this repair's profiles separate and reuse only matching source/object evidence."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

root = Path.cwd().resolve()
out = Path(__file__).resolve().parent
previous = out.parent
build = root / '.build/video-frames/arm64-apple-macosx/debug'
test = build / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
helper = build / 'TypefluxMediaHelper'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(name, value):
    (out / (name + '.json')).write_text(json.dumps(value, indent=2) + '\n')


def compress(path):
    with path.open('rb') as incoming, gzip.open(str(path) + '.gz', 'wb') as outgoing:
        shutil.copyfileobj(incoming, outgoing)


paths = subprocess.check_output(['git', 'ls-files', 'Sources', 'Tests', 'Packages', 'scripts',
                                 'Package.swift', 'Package.resolved'], text=True).splitlines()
inputs = {p: sha(root / p) for p in paths if (root / p).is_file()}
assert inputs == json.loads((out / 'inputs-tested.json').read_text()), 'Tested source inputs changed'
save('inputs-final', inputs)
objects = {str(p.relative_to(root)): sha(p) for p in build.glob('*.build/*.o')}
save('objects-final', objects)
products = [test, helper, build / 'Typeflux', build / 'TypefluxInferenceHelper']
save('binaries-final', {str(p.relative_to(root)): sha(p) for p in products if p.is_file()})
assert sha(helper) == json.loads((out / 'helper-contract.json').read_text())['helper_sha256'], 'Helper binary changed since contract/profile capture'
save('fixtures-final', {str(p.relative_to(root)): sha(p) for folder in (previous, previous.parent / 'video-frames')
                        for p in folder.glob('*.mov')})
save('validation-tools-final', {p.name: sha(p) for p in out.iterdir()
                                if p.suffix in ('.py', '.sh') or p.name == 'test-files.json'})
tools = json.loads((previous / 'tool-binaries.json').read_text())
save('tool-binaries-final', {name: {'path': item['path'], 'sha256': sha(Path(item['path']))}
                             for name, item in tools.items()})
before = json.loads((out / 'profiles-before.json').read_text())
raw = out / 'application-profiles'
raw.mkdir(exist_ok=True)
for p in (build / 'codecov').glob('*.profraw'):
    if before.get(p.name) != sha(p):
        shutil.copy2(p, raw / p.name)

coverage = {}
profiles = {}


def read_lcov(text, admit=lambda p: True):
    path = None
    for line in text.splitlines():
        if line.startswith('SF:'):
            try:
                path = str(Path(line[3:]).resolve().relative_to(root))
                if not admit(path):
                    path = None
            except ValueError:
                path = None
        elif path and line.startswith('DA:'):
            number, count, *_ = line[3:].split(',')
            rows = coverage.setdefault(path, {})
            rows[int(number)] = max(rows.get(int(number), 0), int(count))


for name, binary, folder in (('application', test, raw), ('native-helper', helper, out / 'helper-profiles')):
    inputs_raw = sorted(folder.glob('*.profraw'))
    assert inputs_raw, 'Missing ' + name + ' profiles'
    for p in inputs_raw:
        subprocess.run(['xcrun', 'llvm-profdata', 'show', str(p)], check=True, capture_output=True)
    profiles[name] = {p.name: sha(p) for p in inputs_raw}
    data = out / (name + '.profdata')
    subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, inputs_raw), '-o', str(data)], check=True)
    lcov = out / (name + '.lcov')
    with lcov.open('w') as stream:
        subprocess.run(['xcrun', 'llvm-cov', 'export', str(binary), '--instr-profile=' + str(data),
                        '--format=lcov'], stdout=stream, check=True)
    read_lcov(lcov.read_text(), lambda p: p.startswith('Sources/TypefluxMedia') if name == 'native-helper'
              else p.startswith('Sources/Typeflux/'))
    for p in [data, lcov, *inputs_raw]:
        compress(p)
save('profiles-final', profiles)

reuse = {}
for folder in (previous, previous / 'before-final-fixes'):
    old_sources = json.loads((folder / 'final-source-fingerprints.json').read_text())
    old_objects = json.loads((folder / 'production-objects.json').read_text())
    matched = set()
    for p in old_sources:
        if not p.startswith('Sources/Typeflux/'):
            continue
        obj = str((build / 'Typeflux.build' / (Path(p).name + '.o')).relative_to(root))
        source_matches = inputs.get(p) == old_sources[p]
        object_matches = obj in objects and objects[obj] == old_objects.get(obj)
        reuse.setdefault(str(folder.relative_to(root)), {})[p] = {
            'source_matches': source_matches, 'production_object_matches': object_matches}
        if source_matches and object_matches:
            matched.add(p)
    read_lcov(gzip.decompress((folder / 'application.lcov.gz').read_bytes()).decode(), lambda p: p in matched)
save('coverage-reuse', reuse)

changes = {}
path = None
baseline = '9021ea52fc2696965e0c8a18cbe678f766038f3f'
diff = subprocess.check_output(['git', 'diff', '--unified=0', baseline, '--', 'Sources'], text=True)
for line in diff.splitlines():
    if line.startswith('+++ b/'):
        path = line[6:]
        changes.setdefault(path, set())
    elif path and (match := re.match(r'@@ .*\+(\d+)(?:,(\d+))? @@', line)):
        start, count = int(match[1]), int(match[2] or 1)
        changes[path].update(range(start, start + count))
files = {}
for p, additions in changes.items():
    if not p.endswith('.swift'):
        continue
    assert p in coverage, 'Missing coverage mapping for changed Swift source: ' + p
    rows = {n: c for n, c in coverage[p].items() if n in additions}
    files[p] = {'covered': sum(c > 0 for c in rows.values()), 'executable': len(rows),
                'uncovered': sorted(n for n, c in rows.items() if not c)}
filesystem = {'SemanticVideoFrames.swift', 'SemanticAudioWindows.swift', 'SemanticMediaExtractor.swift'}
groups = {}
for name in ('application', 'filesystem_helper', 'native_media_runtime'):
    rows = [v for p, v in files.items() if
            (name == 'filesystem_helper' and Path(p).name in filesystem) or
            (name == 'application' and p.startswith('Sources/Typeflux/') and Path(p).name not in filesystem) or
            (name == 'native_media_runtime' and p.startswith('Sources/TypefluxMedia'))]
    covered, total = sum(v['covered'] for v in rows), sum(v['executable'] for v in rows)
    groups[name] = {'covered': covered, 'executable': total,
                    'percent': round(100 * covered / total, 2) if total else None}
save('changed-coverage', {'baseline': baseline, 'denominator': 'Git added/modified executable Swift lines intersected with LLVM LCOV DA records; line coverage, not branch coverage.',
                         'groups': groups, 'files': files})
for p in out.glob('*.log'):
    compress(p)
print(json.dumps(groups))
