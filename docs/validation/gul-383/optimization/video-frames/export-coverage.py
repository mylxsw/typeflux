#!/usr/bin/env python3
"""Export matching current-binary profiles, preserving invalid inputs and their errors."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
evidence = Path(__file__).resolve().parent
build = root / '.build/video-frames/arm64-apple-macosx/debug'
binary = build / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
raw = evidence / 'raw-profiles'
raw.mkdir(exist_ok=True)
for source in (build / 'codecov').glob('*.profraw'):
    shutil.copy2(source, raw / source.name)
inputs = []
checks = {}
for source in sorted(raw.glob('*.profraw')):
    result = subprocess.run(['xcrun', 'llvm-profdata', 'show', str(source)], capture_output=True, text=True)
    checks[source.name] = {'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                           'exit_code': result.returncode, 'error': result.stderr.strip()}
    if result.returncode == 0:
        inputs.append(source)
(evidence / 'profile-inputs.json').write_text(json.dumps(checks, indent=2) + '\n')
if not inputs:
    raise SystemExit('No valid profiles to export')
profile = evidence / 'application.profdata'
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', '--function=8Typeflux',
                '--no-function=TypefluxFocusedTests', *map(str, inputs), '-o', str(profile)], check=True)
with (evidence / 'application.lcov').open('w') as output:
    subprocess.run(['xcrun', 'llvm-cov', 'export', str(binary), '--instr-profile=' + str(profile),
                    '--format=lcov'], stdout=output, check=True)
objects = {str(file.relative_to(root)): hashlib.sha256(file.read_bytes()).hexdigest()
           for file in sorted((build / 'Typeflux.build').glob('*.o'))}
(evidence / 'production-objects.json').write_text(json.dumps(objects, indent=2) + '\n')
(evidence / 'binary-sha256.json').write_text(json.dumps({str(binary.relative_to(root)):
    hashlib.sha256(binary.read_bytes()).hexdigest()}, indent=2) + '\n')
subprocess.run(['python3', str(evidence / 'coverage-summary.py'), '--lcov', str(evidence / 'application.lcov')], check=True)
