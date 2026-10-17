#!/usr/bin/env python3
"""Remove test-module counters before merging identical production objects across test-only repairs."""
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path.cwd()
out = Path(__file__).resolve().parent
before = json.loads((out / 'changed-coverage.json').read_text())
candidates = []
for directory in ('application-profiles', 'first-pass-profiles', 'repair-pass-profiles'):
    candidates += list((out / directory).glob('*.profraw*'))
profiles = {}
for path in candidates:
    data = gzip.decompress(path.read_bytes()) if path.suffix == '.gz' else path.read_bytes()
    profiles.setdefault(hashlib.sha256(data).hexdigest(), (path, data))
records = []
with tempfile.TemporaryDirectory(prefix='download-profile-', dir=root / '.build') as temporary:
    temporary = Path(temporary)
    filtered = []
    for index, (digest, (source, data)) in enumerate(profiles.items()):
        raw = temporary / f'{index}.profraw'
        raw.write_bytes(data)
        target = temporary / f'{index}.profdata'
        process = subprocess.run(['xcrun', 'llvm-profdata', 'merge', '--sparse',
            '--no-function=TypefluxFocusedTests', str(raw), '-o', str(target)],
            check=True, capture_output=True, text=True)
        filtered.append(target)
        records.append({'source': str(source.relative_to(out)), 'raw_sha256': digest,
                        'filter': 'TypefluxFocusedTests', 'filter_output': process.stdout + process.stderr})
    merged = temporary / 'application.profdata'
    result = subprocess.run(['xcrun', 'llvm-profdata', 'merge', '--sparse', *map(str, filtered), '-o', str(merged)],
                            check=False, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    assert not result.stderr, result.stderr
    binary = root / '.build/video-frames/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
    export = subprocess.check_output(['xcrun', 'llvm-cov', 'export', str(binary),
        '--instr-profile=' + str(merged), '--format=lcov'])
    lcov = temporary / 'application.lcov'; lcov.write_bytes(export)
    subprocess.run(['python3', str(out.parent / 'changed_coverage.py'), '--base', before['baseline'],
        '--lcov', str(lcov), '--output', str(out / 'changed-coverage.json')], check=True)
    after = json.loads((out / 'changed-coverage.json').read_text())
    assert after == before, 'Production coverage changed when removing test-only counters'
    for path, data in [(out / 'application.profdata.gz', merged.read_bytes()), (out / 'application.lcov.gz', export)]:
        with gzip.open(path, 'wb') as stream: stream.write(data)
(out / 'clean-profile-processing.json').write_text(json.dumps({
    'production_source_and_object_match_required': True,
    'production_coverage_identical_to_unfiltered_merge': True,
    'merge_stderr': result.stderr, 'profiles': records}, indent=2) + '\n')
print('Clean application coverage unchanged; test counters excluded before merge; no merge diagnostics.')
