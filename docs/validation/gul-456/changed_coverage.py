"""Intersect raw LLVM LCOV with changed source lines, including from another checkout."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

BASELINE = '3256b06c03cd22b9c069853912954b8d1d07f8fc'
PREFIX = 'Sources/Typeflux/Ask/'
EXPECTED = {
    PREFIX + name: executable
    for name, executable in {
        'AskModelCompleting.swift': False,
        'AskCustomInference.swift': False,
        'AskConversationModel.swift': True,
        'AskConversationModel+Title.swift': True,
        'AskConversationWindowController.swift': True,
        'Local/AskAuxiliaryInference.swift': True,
        'QuickResults/Plugins/Workflow/Editor/AskWorkflowAssistant.swift': True,
    }.items()
}


def repository_path(source):
    """Keep raw SF provenance untouched; match exactly one repository source suffix."""
    parts = PurePosixPath(source).parts
    anchors = [i for i in range(len(parts) - 1) if parts[i:i + 2] == ('Sources', 'Typeflux')]
    if len(anchors) != 1:
        raise ValueError(f'Ambiguous or missing Sources/Typeflux path: {source}')
    suffix = parts[anchors[0]:]
    if '..' in suffix:
        raise ValueError(f'Noncanonical source path: {source}')
    return '/'.join(suffix)


def parse_lcov(raw):
    records = {}
    current = None
    for line in raw.splitlines():
        if line.startswith('SF:'):
            current = repository_path(line[3:])
            records.setdefault(current, {})
        elif line.startswith('DA:'):
            if current is None:
                raise ValueError('DA record without SF')
            number, hits, *_ = line[3:].split(',')
            number, hits = int(number), int(hits)
            if number < 1 or hits < 0:
                raise ValueError('Invalid executable record')
            records[current][number] = max(records[current].get(number, 0), hits)
        elif line == 'end_of_record':
            current = None
    return records


def changed_lines(root):
    diff = subprocess.check_output(
        ['git', 'diff', BASELINE, '--unified=0', '--', 'Sources/Typeflux/Ask'], cwd=root, text=True
    )
    changed = {}
    current = None
    for line in diff.splitlines():
        if line.startswith('+++ b/'):
            current = line[6:]
        elif line.startswith('@@'):
            match = re.search(r'\+(\d+)(?:,(\d+))?', line)
            start, count = int(match[1]), int(match[2] or 1)
            changed.setdefault(current, set()).update(range(start, start + count))
    if set(changed) != set(EXPECTED):
        raise ValueError(f'Changed file inventory differs: {sorted(set(changed) ^ set(EXPECTED))}')
    return changed


def executable_lines(changed, records):
    result = {}
    for source, additions in sorted(changed.items()):
        if EXPECTED[source] and source not in records:
            raise ValueError(f'Missing expected LCOV file: {source}')
        result[source] = {n: hits for n, hits in records.get(source, {}).items() if n in additions}
        if EXPECTED[source] and not result[source]:
            raise ValueError(f'Missing expected changed executable records: {source}')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', action='store_true', help='Export fresh raw LCOV from the local instrumented run')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    directory = root / 'docs/validation/gul-456'
    artifact = directory / 'changed-files.lcov.gz'
    manifest_file = directory / 'changed-executable-lines.json'
    changed = changed_lines(root)
    if args.export:
        bin_path = Path(subprocess.check_output(['swift', 'build', '--build-system', 'native', '--show-bin-path'], cwd=root, text=True).strip())
        binary = bin_path / 'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
        profile = bin_path / 'codecov/default.profdata'
        command = ['xcrun', 'llvm-cov', 'export', str(binary), '-instr-profile=' + str(profile),
                   '-format=lcov', *[str(root / f) for f in sorted(changed)]]
        raw = subprocess.check_output(command, text=True)
        print('Export command:', repr(command))
    else:
        raw = gzip.decompress(artifact.read_bytes()).decode()
    executable = executable_lines(changed, parse_lcov(raw))
    manifest = {
        source: {'sha256': hashlib.sha256((root / source).read_bytes()).hexdigest(),
                 'lines': sorted(records)}
        for source, records in executable.items()
    }
    if args.export:
        artifact.write_bytes(gzip.compress(raw.encode(), mtime=0))
        manifest_file.write_text(json.dumps(manifest, indent=2) + '\n')
    elif manifest != json.loads(manifest_file.read_text()):
        raise ValueError('Source hashes or expected executable records differ; refresh from an instrumented run')
    print(f'Baseline: {BASELINE} (main after PR #694)')
    print('Denominator: added/modified production lines with LLVM DA records; excludes declarations, comments and tests.')
    covered = total = 0
    for source, records in executable.items():
        hit = sum(hits > 0 for hits in records.values())
        covered += hit
        total += len(records)
        print(f'{source}: {hit}/{len(records)}; uncovered: {[n for n, hits in records.items() if hits == 0]}')
    if total == 0:
        raise ValueError('No changed executable records')
    print(f'Changed executable line coverage: {covered}/{total} = {100 * covered / total:.2f}%')


if __name__ == '__main__':
    main()
