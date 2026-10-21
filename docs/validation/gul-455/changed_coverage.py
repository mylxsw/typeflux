"""Intersect LLVM LCOV executable lines with added production lines vs main."""
from pathlib import Path
import re
import gzip
import sys
import subprocess

root = Path(__file__).resolve().parents[3]
diff = subprocess.check_output(['git', 'diff', '307ae12f', '--unified=0', '--', 'Sources/Typeflux/Ask'], cwd=root, text=True)
changed = {}
file = None
for line in diff.splitlines():
    if line.startswith('+++ b/'):
        file = line[6:]
    elif line.startswith('@@'):
        match = re.search(r'\+(\d+)(?:,(\d+))?', line)
        start, count = int(match[1]), int(match[2] or 1)
        changed.setdefault(file, set()).update(range(start, start + count))

binary = root / '.build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
profile = root / '.build/arm64-apple-macosx/debug/codecov/default.profdata'
command = ['xcrun', 'llvm-cov', 'export', str(binary), '-instr-profile=' + str(profile), '-format=lcov', *[str(root / f) for f in changed]]
artifact = root / 'docs/validation/gul-455/changed-files.lcov.gz'
if '--export' in sys.argv:
    raw = subprocess.check_output(command, text=True)
    artifact.write_bytes(gzip.compress(raw.encode(), mtime=0))
else:
    raw = gzip.decompress(artifact.read_bytes()).decode()
print('Command:', repr(command))
print('Baseline: 307ae12f (main after PR #693)')
print('Denominator: added/modified production lines with LLVM DA records; excludes declarations, comments and tests.')
covered = total = 0
lines = {}
for line in raw.splitlines():
    if line.startswith('SF:'):
        file = str(Path(line[3:]).relative_to(root))
        lines.setdefault(file, {})
    elif line.startswith('DA:'):
        number, hits, *_ = line[3:].split(',')
        lines[file][int(number)] = max(lines[file].get(int(number), 0), int(hits))
for file, additions in sorted(changed.items()):
    executable = {n: hits for n, hits in lines.get(file, {}).items() if n in additions}
    hit = sum(hits > 0 for hits in executable.values())
    total += len(executable)
    covered += hit
    print(f'{file}: {hit}/{len(executable)}; uncovered: {[n for n, hits in executable.items() if hits == 0]}')
print(f'Changed executable line coverage: {covered}/{total} = {100 * covered / total:.2f}%')
