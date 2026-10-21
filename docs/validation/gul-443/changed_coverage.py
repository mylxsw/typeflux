"""Portable changed executable-line coverage from Go profiles or LLVM export JSON.

Usage: changed_coverage.py --repo REPO --base SHA (--go FILE ... | --llvm FILE)
       --file RELATIVE_SOURCE ...
Go block counts and LLVM active-region counts are combined by maximum per line.
Only lines both added/modified by git diff and instrumented are in the denominator.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path


def changed_lines(repo, base, file):
    diff = subprocess.check_output(['git', '-C', repo, 'diff', '--unified=0', base, '--', file], text=True)
    lines = set()
    for start, count in re.findall(r'^@@ .*?\+(\d+)(?:,(\d+))? @@', diff, re.M):
        lines.update(range(int(start), int(start) + int(count or 1)))
    return lines


def go_lines(profiles, file):
    lines = {}
    for profile in profiles:
        for row in Path(profile).read_text().splitlines()[1:]:
            match = re.match(r'(.+):(\d+)\.\d+,(\d+)\.\d+ \d+ (\d+)$', row)
            if match and match[1].endswith('/' + file):
                for line in range(int(match[2]), int(match[3]) + 1):
                    lines[line] = max(lines.get(line, 0), int(match[4]))
    return lines


def llvm_lines(raw, file):
    lines = {}
    for unit in raw['data']:
        for item in unit['files']:
            if not item['filename'].endswith('/' + file):
                continue
            segments = item['segments']
            for current, following in zip(segments, segments[1:]):
                start, col, count, has_count, *_ = current
                gap = len(current) > 5 and current[5]
                if not has_count or gap:
                    continue
                # The active region ends just before the following segment.
                end = following[0] - (following[1] == 1)
                for line in range(start, end + 1):
                    lines[line] = max(lines.get(line, 0), count)
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--base', required=True)
    parser.add_argument('--go', action='append', default=[])
    parser.add_argument('--llvm')
    parser.add_argument('--file', action='append', required=True)
    args = parser.parse_args()
    if bool(args.go) == bool(args.llvm):
        parser.error('Choose Go profiles or LLVM export')
    raw = json.loads(Path(args.llvm).read_text()) if args.llvm else None
    result = {}; total = covered = 0
    for file in args.file:
        measured = llvm_lines(raw, file) if raw else go_lines(args.go, file)
        changed = changed_lines(args.repo, args.base, file)
        executable = changed & measured.keys()
        hit = sum(measured[line] > 0 for line in executable)
        total += len(executable); covered += hit
        result[file] = {'covered': hit, 'executable': len(executable), 'uncovered': sorted(line for line in executable if not measured[line])}
    result['total'] = {'covered': covered, 'executable': total, 'percent': round(100 * covered / total, 2) if total else None}
    print(json.dumps(result, indent=2))
    if not total or covered / total < 0.90:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
