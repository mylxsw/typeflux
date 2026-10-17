#!/usr/bin/env python3
"""Export only unchanged application objects across the focused method retries."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
evidence = Path(__file__).resolve().parent
build = root / '.build/pdf-preview/arm64-apple-macosx/debug'
objects = json.loads((evidence / 'production-object-hashes-before-native-retry.json').read_text())
comparison = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
              for name, digest in objects.items()}
if not all(comparison.values()):
    raise SystemExit('Production objects changed; refusing to combine profiles.')
(evidence / 'production-object-comparison.json').write_text(json.dumps(comparison, indent=2) + '\n')
raw = evidence / 'final-capability-raw'
raw.mkdir(exist_ok=True)
for source in (build / 'codecov').glob('*.profraw'):
    shutil.copy2(source, raw / source.name)
groups = {
    'focused': [evidence / 'final-focused.profdata'],
    'native': list((evidence / 'final-native-raw').glob('*.profraw')),
    'capability': list(raw.glob('*.profraw')),
    'confirmation': list(evidence.glob('native-confirm-*.profraw')),
}
outputs = []
for name, inputs in groups.items():
    if not inputs:
        raise SystemExit('Missing raw profiles: ' + name)
    output = evidence / (name + '-application.profdata')
    # Test method bodies changed during fixture repairs. Exclude them before merging;
    # the ten application objects above and their coverage mappings are identical.
    subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', '--function=8Typeflux',
                    '--no-function=TypefluxFocusedTests', *map(str, inputs), '-o', str(output)], check=True)
    outputs.append(output)
profile = evidence / 'final-application.profdata'
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, outputs), '-o', str(profile)], check=True)
with (evidence / 'final-application.lcov').open('w') as output:
    subprocess.run(['xcrun', 'llvm-cov', 'export',
                    str(build / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'),
                    '--instr-profile=' + str(profile), '--format=lcov',
                    r'--ignore-filename-regex=(/\.build/|/Tests/)'], stdout=output, check=True)
subprocess.run(['python3', str(evidence / 'coverage-summary.py'), '--lcov',
                str(evidence / 'final-application.lcov')], check=True)
