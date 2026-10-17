#!/usr/bin/env python3
"""Freeze the fixture-only repair and export its single focused coverage run."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

root = Path.cwd().resolve()
out = Path(__file__).resolve().parent
proof = out.parent
build = root / '.build/video-frames/arm64-apple-macosx/debug'
binary = build / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def save(name, value):
    (out / (name + '.json')).write_text(json.dumps(value, indent=2) + '\n')


def compressed(source, target):
    with source.open('rb') as incoming, gzip.open(target, 'wb') as outgoing:
        while block := incoming.read(1024 * 1024):
            outgoing.write(block)


sources = json.loads((proof / 'source-fingerprints.json').read_text())
current = {path: sha(root / path) for path in sources}
assert [p for p in sources if sources[p] != current[p]] == [
    'Tests/TypefluxTests/SemanticVideoFrameTests.swift']
test_path = 'Tests/TypefluxTests/SemanticVideoFrameTests.swift'
marker = '@Test func `recipe upgrade is video only and invalid progress rolls back vector`'
original = subprocess.check_output([
    'git', 'show', 'f9c7aed270e7d4a399d487d5081345907933a2ad:' + test_path], text=True)
repaired = (root / test_path).read_text()
assert original[original.index(marker):] == repaired[repaired.index(marker):]
save('source-fingerprints', current)
objects = json.loads((proof / 'production-objects.json').read_text())
assert all(sha(root / path) == value for path, value in objects.items())
save('production-objects', objects)
save('binary-sha256', {str(binary.relative_to(root)): sha(binary)})
tools = json.loads((proof / 'tool-binaries.json').read_text())
assert all(sha(Path(value['path'])) == value['sha256'] for value in tools.values())
save('tool-binaries', tools)
fixtures = {path.name: sha(path) for path in sorted(proof.glob('*.mov'))}
assert fixtures == json.loads((out / 'before-audit.json').read_text())['fixtures']
save('fixture-sha256', fixtures)
profiles = sorted((build / 'codecov').glob('*.profraw'))
assert profiles
profile_dir = out / 'raw-profiles'
profile_dir.mkdir(exist_ok=True)
checks = {}
for path in profiles:
    result = subprocess.run(['xcrun', 'llvm-profdata', 'show', str(path)],
                            capture_output=True, text=True)
    checks[path.name] = {'sha256': sha(path), 'exit_code': result.returncode,
                         'stderr': result.stderr}
    assert result.returncode == 0, checks[path.name]
    compressed(path, profile_dir / (path.name + '.gz'))
save('profile-inputs', checks)

with tempfile.TemporaryDirectory(prefix='fixture-repair-export-', dir=root / '.build') as temporary:
    temporary = Path(temporary)
    profile, lcov = temporary / 'focused.profdata', temporary / 'focused.lcov'
    subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', '--function=Typeflux',
                    *map(str, profiles), '-o', str(profile)], check=True)
    with lcov.open('w') as output:
        subprocess.run(['xcrun', 'llvm-cov', 'export', str(binary),
                        '--instr-profile=' + str(profile), '--format=lcov'],
                       stdout=output, check=True)
    values, path = {}, None
    for line in lcov.read_text().splitlines():
        if line.startswith('SF:'):
            try:
                path = str(Path(line[3:]).resolve().relative_to(root))
            except ValueError:
                path = None
        elif path and line.startswith('DA:'):
            number, count, *_ = line[3:].split(',')
            rows = values.setdefault(path, {})
            rows[int(number)] = max(rows.get(int(number), 0), int(count))
    compressed(profile, out / 'focused.profdata.gz')
    compressed(lcov, out / 'focused.lcov.gz')


def changed_coverage(base, scope):
    additions, path = {}, None
    diff = subprocess.check_output(['git', 'diff', '--unified=0', base, '--', scope], text=True)
    for line in diff.splitlines():
        if line.startswith('+++ b/'):
            path = line[6:]
            additions.setdefault(path, set())
        elif path and (match := re.match(r'@@ .*\+(\d+)(?:,(\d+))? @@', line)):
            first, count = int(match[1]), int(match[2] or 1)
            additions[path].update(range(first, first + count))
    report = {}
    for path, lines in additions.items():
        rows = {line: count for line, count in values.get(path, {}).items() if line in lines}
        report[path] = {'covered': sum(count > 0 for count in rows.values()),
                        'executable': len(rows),
                        'uncovered': [line for line, count in rows.items() if not count]}
    return report


save('focused-changed-coverage', {
    'production_against_pr636': changed_coverage('67da58f9d03826d26095cf635f8e1d35dcc57006', 'Sources'),
    'fixture_repair_against_previous_head': changed_coverage(
        'f9c7aed270e7d4a399d487d5081345907933a2ad', 'Tests/TypefluxTests/SemanticVideoFrameTests.swift'),
    'denominator': 'Git added/modified lines intersected with LLVM DA executable lines, line coverage only'
})
save('final-match', {'source_inputs': len(current), 'changed_source_inputs': 1,
                     'identical_production_objects': len(objects), 'identical_tools': len(tools),
                     'identical_real_mov_fixtures': len(fixtures), 'raw_profiles': len(profiles),
                     'unchanged_recipe_rollback_method_sha256': hashlib.sha256(
                         repaired[repaired.index(marker):].encode()).hexdigest(),
                     'production_sources_unchanged': not subprocess.check_output([
                         'git', 'diff', 'f9c7aed270e7d4a399d487d5081345907933a2ad', '--', 'Sources'])})
print((out / 'final-match.json').read_text())
