#!/usr/bin/env python3
"""Collect only this run's new profiles and changed executable application lines."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

root = Path.cwd().resolve()
out = Path(__file__).resolve().parent
build = root / '.build/video-frames/arm64-apple-macosx/debug'
base = '3b63419580ea6e01c8187161d903f28ce396ee59'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def save(name, value):
    (out / (name + '.json')).write_text(json.dumps(value, indent=2) + '\n')

paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard',
    'Sources', 'Tests', 'Packages', 'scripts', 'Package.swift', 'Package.resolved'], text=True).splitlines()
inputs = {p: sha(root / p) for p in paths if (root / p).is_file()}
assert inputs == json.loads((out / 'inputs-tested.json').read_text()), 'Inputs changed since test freeze'
save('inputs-final', inputs)
products = [build / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests',
            build / 'Typeflux', build / 'TypefluxMediaHelper', build / 'TypefluxInferenceHelper']
save('binaries-final', {str(p.relative_to(root)): sha(p) for p in products if p.is_file()})
save('objects-final', {str(p.relative_to(root)): sha(p) for p in build.glob('*.build/*.o')})
before = json.loads((out / 'profiles-before.json').read_text())
raw = out / 'application-profiles'
raw.mkdir(exist_ok=True)
for p in (build / 'codecov').glob('*.profraw'):
    if before.get(str(p.relative_to(root))) != sha(p):
        shutil.copy2(p, raw / p.name)
first_objects = json.loads((out / 'objects-first-pass.json').read_text())
current_objects = {str(p.relative_to(root)): sha(p) for p in (build / 'Typeflux.build').glob('*.o')}
assert current_objects == first_objects, 'Production objects changed; cannot reuse first/second-pass counters'
production_inputs = {p: v for p, v in inputs.items() if p.startswith('Sources/')}
assert production_inputs == json.loads((out / 'production-inputs-first-pass.json').read_text())
candidates = [*raw.glob('*.profraw'), *out.glob('first-pass-profiles/*.profraw'), *out.glob('second-pass-profiles/*.profraw')]
original_hashes = set(before.values())
profiles = list({sha(p): p for p in candidates if sha(p) not in original_hashes}.values())
save('coverage-reuse', {'source_match': True, 'production_object_match': True,
    'production_objects': len(current_objects), 'profiles': [str(p.relative_to(out)) for p in profiles],
    'scope': 'Nine distinct methods passed across three runs (7 initial methods, 4 repair methods, 1 final method); failures retained; not a single final nine-method run.'})
assert profiles, 'No profiles from this run'
merged = out / 'application.profdata'
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '--sparse', *map(str, profiles), '-o', str(merged)], check=True)
export = subprocess.check_output(['xcrun', 'llvm-cov', 'export', str(products[0]),
    '--instr-profile=' + str(merged), '--format=lcov'], text=True)
with gzip.open(out / 'application.lcov.gz', 'wt') as stream:
    stream.write(export)
coverage = {}
path = None
for line in export.splitlines():
    if line.startswith('SF:'):
        p = Path(line[3:])
        path = str(p.relative_to(root)) if p.is_relative_to(root) else None
        if path is not None: coverage.setdefault(path, {})
    elif path is not None and line.startswith('DA:'):
        number, count = map(int, line[3:].split(',')[:2])
        coverage[path][number] = max(count, coverage[path].get(number, 0))
changes = {}
path = None
for line in subprocess.check_output(['git', 'diff', '-U0', base, '--', 'Sources'], text=True).splitlines():
    if line.startswith('+++ b/'):
        path = line[6:]; changes.setdefault(path, set())
    elif path and (m := re.match(r'@@ .*\+(\d+)(?:,(\d+))? @@', line)):
        start, count = int(m[1]), int(m[2] or 1)
        changes[path].update(range(start, start + count))
files = {}
for p, added in changes.items():
    if not p.endswith('.swift'): continue
    assert p in coverage, 'No mapping for ' + p
    rows = {n: c for n, c in coverage[p].items() if n in added}
    files[p] = {'covered': sum(c > 0 for c in rows.values()), 'executable': len(rows),
                'uncovered': sorted(n for n, c in rows.items() if not c)}
covered = sum(p['covered'] for p in files.values()); total = sum(p['executable'] for p in files.values())
save('changed-coverage', {'baseline': base, 'denominator': 'Git added/modified executable Swift lines intersected with LLVM LCOV DA records; line coverage, not branch coverage.',
    'application': {'covered': covered, 'executable': total, 'percent': round(100 * covered / total, 2)},
    'filesystem_helper': {'covered': 0, 'executable': 0, 'status': 'No source changes'},
    'native_media_runtime': {'covered': 0, 'executable': 0, 'status': 'No source changes'}, 'files': files})
save('profiles-final', {str(p.relative_to(out)): sha(p) for p in [*profiles, merged]})
for p in sorted(set([*candidates, merged, *(out / 'first-pass-profiles').glob('*.profdata')])):
    with p.open('rb') as incoming, gzip.open(str(p) + '.gz', 'wb') as target:
        shutil.copyfileobj(incoming, target)
    p.unlink()
save('validation-tools', {p.name: sha(p) for p in out.iterdir() if p.suffix in ('.py', '.sh') or p.name == 'test-files.json'})
for p in out.glob('*.log'):
    with p.open('rb') as incoming, gzip.open(str(p) + '.gz', 'wb') as target:
        shutil.copyfileobj(incoming, target)
    p.unlink()
print(json.dumps({'covered': covered, 'executable': total}))
