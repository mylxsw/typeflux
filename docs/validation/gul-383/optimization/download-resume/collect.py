#!/usr/bin/env python3
"""Freeze tested inputs, new LLVM profiles, actual binaries and changed executable lines."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path.cwd().resolve()
out = Path(__file__).resolve().parent
build = root / '.build/video-frames/arm64-apple-macosx/debug'
base = '55985dbd039f320f6771aa8a64c4f632bec43cd2'
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
first_objects = json.loads((out / 'production-objects-first-pass.json').read_text())
current_objects = {str(p.relative_to(root)): sha(p) for p in (build / 'Typeflux.build').glob('*.o')}
assert current_objects == first_objects, 'Application production objects changed between fixture-only repairs'
first_inputs = json.loads((out / 'inputs-first-pass.json').read_text())
assert {p: v for p, v in inputs.items() if p.startswith('Sources/')} == {p: v for p, v in first_inputs.items() if p.startswith('Sources/')}
profiles = list({sha(p): p for p in [*raw.glob('*.profraw'), *out.glob('first-pass-profiles/*.profraw'), *out.glob('repair-pass-profiles/*.profraw')]}.values())
save('profile-reuse', {'application_source_and_objects_match': True,
    'production_objects': len(current_objects),
    'scope': 'Reuse the two passing media caller methods from the first execution. The repaired ten-method scope passed; the final one-method run strengthens the production metadata identity assertion. The three text methods were missed by the original pattern. No old baseline profiles.'})
assert profiles, 'No profiles from this run'
merged = out / 'application.profdata'
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '--sparse', *map(str, profiles), '-o', str(merged)], check=True)
export = subprocess.check_output(['xcrun', 'llvm-cov', 'export', str(products[0]),
    '--instr-profile=' + str(merged), '--format=lcov'])
with gzip.open(out / 'application.lcov.gz', 'wb') as stream:
    stream.write(export)
lcov = out / 'application.lcov'
lcov.write_bytes(export)
subprocess.run(['python3', str(out.parent / 'changed_coverage.py'), '--base', base,
                '--lcov', str(lcov), '--output', str(out / 'changed-coverage.json')], check=True)
lcov.unlink()
save('unchanged-native-coverage', {'filesystem_helper': {'covered': 0, 'executable': 0, 'status': 'No source changes'},
                                  'native_media_runtime': {'covered': 0, 'executable': 0, 'status': 'No source changes'}})
save('profiles-final', {str(p.relative_to(out)): sha(p) for p in [*profiles, merged]})
for p in [*profiles, merged]:
    with p.open('rb') as incoming, gzip.open(str(p) + '.gz', 'wb') as target:
        shutil.copyfileobj(incoming, target)
    p.unlink()
tools = [Path('/usr/bin/swift'), Path('/usr/bin/python3'), Path('/opt/homebrew/bin/swiftlint')]
for name in ('llvm-cov', 'llvm-profdata'):
    tools.append(Path(subprocess.check_output(['xcrun', '--find', name], text=True).strip()))
save('tools-final', {str(p): sha(p) for p in tools})
subprocess.run(['git', 'diff', '--binary', base, '--', 'Sources', 'Tests', 'scripts/fixtures'],
               stdout=(out / 'source.patch').open('wb'), check=True)
print(json.dumps({'inputs': len(inputs), 'objects': len(list(build.glob('*.build/*.o'))),
                  'binaries': len([p for p in products if p.is_file()]), 'profiles': len(profiles)}))
