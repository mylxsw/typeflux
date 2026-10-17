#!/usr/bin/env python3
"""Freeze current inputs, binaries, tools, fixtures and valid current-run coverage."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path.cwd().resolve()
out = Path(__file__).resolve().parent
build = root / '.build/video-frames/arm64-apple-macosx/debug'
binary = build / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'

def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

def save(name, value):
    (out / (name + '.json')).write_text(json.dumps(value, indent=2) + '\n')

def compress(source, target):
    with source.open('rb') as incoming, gzip.open(target, 'wb') as outgoing:
        shutil.copyfileobj(incoming, outgoing)

paths = set(subprocess.check_output(['git', 'ls-files', 'Sources', 'Tests', 'Packages', 'scripts',
                                    'Package.swift', 'Package.resolved'], text=True).splitlines())
paths.update(subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard',
                                     'Sources', 'Tests'], text=True).splitlines())
save('final-source-fingerprints', {p: sha(root / p) for p in sorted(paths) if (root / p).is_file()})
save('production-objects', {str(p.relative_to(root)): sha(p) for p in sorted((build / 'Typeflux.build').glob('*.o'))})
binaries = [binary] + [build / name for name in ('Typeflux', 'TypefluxMediaHelper', 'TypefluxInferenceHelper')]
save('binary-sha256', {str(p.relative_to(root)): sha(p) for p in binaries if p.is_file()})
old_tools = json.loads((out.parent / 'video-frames/tool-binaries.json').read_text())
tools = {name: {'path': value['path'], 'sha256': sha(Path(value['path']))}
         for name, value in old_tools.items()}
for name in ('ffmpeg', 'ffprobe'):
    path = Path(shutil.which(name)).resolve()
    tools[name] = {'path': str(path), 'sha256': sha(path)}
save('tool-binaries', tools)
save('model-inputs', {'weights_loaded': False, 'vectors': 'fixed synthetic unit vectors; no transcription',
    'declared_embedding_sha256': '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135',
    'declared_projector_sha256': 'c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f'})
fixtures = list(out.glob('*.mov')) + list((out.parent / 'video-frames').glob('*.mov'))
save('fixture-sha256', {str(p.relative_to(root)): sha(p) for p in fixtures})
save('validation-tools-sha256', {p.name: sha(p) for p in sorted(out.iterdir())
                                if p.suffix in ('.py', '.sh') or p.name == 'test-files.json'})
raw = out / 'raw-profiles'
raw.mkdir(exist_ok=True)
all_profiles = sorted((build / 'codecov').glob('*.profraw'))
# The first attempt did not execute tests. Profiles older than its completion are copied caches.
cutoff = (out / 'coverage-method-retry.json').stat().st_mtime if (out / 'before-final-fixes').exists() else (out / 'coverage-build-retry.json').stat().st_mtime
profiles = [p for p in all_profiles if p.stat().st_mtime >= cutoff]
save('excluded-old-profiles', {p.name: {'sha256': sha(p), 'reason': 'copied profile predates this run'}
                               for p in all_profiles if p not in profiles})
checks = {}
valid = []
for p in profiles:
    result = subprocess.run(['xcrun', 'llvm-profdata', 'show', str(p)], capture_output=True, text=True)
    checks[p.name] = {'sha256': sha(p), 'exit_code': result.returncode, 'stderr': result.stderr}
    compress(p, raw / (p.name + '.gz'))
    if result.returncode == 0:
        valid.append(p)
save('profile-inputs', checks)
if not valid:
    raise SystemExit('No valid current profiles')
profile = out / 'application.profdata'
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', '--function=8Typeflux',
                '--no-function=TypefluxFocusedTests', *map(str, valid), '-o', str(profile)], check=True)
lcov = out / 'application.lcov'
with lcov.open('w') as output:
    subprocess.run(['xcrun', 'llvm-cov', 'export', str(binary), '--instr-profile=' + str(profile),
                    '--format=lcov'], stdout=output, check=True)
subprocess.run(['python3', str(out / 'coverage-summary.py'), '--lcov', str(lcov)], check=True)
compress(profile, out / 'application.profdata.gz')
compress(lcov, out / 'application.lcov.gz')
for p in out.glob('*.log'):
    compress(p, p.with_suffix(p.suffix + '.gz'))
print(json.dumps({'inputs': len(paths), 'objects': len(list((build / 'Typeflux.build').glob('*.o'))),
                  'profiles': len(valid), 'binary': sha(binary)}))
