#!/usr/bin/env python3
"""Export the latest focused profiles before another build changes their counters."""
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
output = Path(__file__).resolve().parent
name = sys.argv[1]
debug = root / '.build/arm64-apple-macosx/debug'
profiles = sorted((debug / 'codecov').glob('*.profraw'))
profile = output / (name + '.profdata')
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, profiles), '-o', str(profile)], check=True)
paths = [p for p in subprocess.check_output(['git', 'diff', '--name-only'], text=True).splitlines()
         if p.startswith('Sources/') and p.endswith('.swift')]
binary = debug / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
data = subprocess.check_output(['xcrun', 'llvm-cov', 'export', '-format=lcov', str(binary),
                                '--instr-profile=' + str(profile), *paths])
with gzip.open(output / (name + '.lcov.gz'), 'wb') as stream:
    stream.write(data)
(output / (name + '-source-hashes.json')).write_text(json.dumps(
    {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths}, indent=2) + '\n')
