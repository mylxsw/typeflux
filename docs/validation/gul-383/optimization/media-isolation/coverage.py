#!/usr/bin/env python3
"""Report changed native-helper LLVM lines from the actual fixed-helper process profiles."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    started = time.monotonic()
    root = Path.cwd()
    out = Path(__file__).resolve().parent
    scratch = root / '.build/media-isolation'
    binary = scratch / 'TypefluxSemanticHelper-coverage'
    built = json.loads((out / 'helper-build.json').read_text())
    assert sha(binary) == built['binary_sha256']
    pids = set()
    for directory in [out / name for name in ['screenshot-fixed', 'audio-fixed', 'video-fixed', 'startup-fixed']]:
        path = directory / 'process-and-persistence.json'
        if not path.exists():
            continue
        identity = json.loads((directory / 'runtime-fingerprints.json').read_text())
        assert identity['model-helper']['sha256'] == built['binary_sha256']
        for sample in json.loads(path.read_text()):
            for process in sample['processes']:
                if process[-1].endswith('/TypefluxSemanticHelper-coverage'):
                    pids.add(int(process[0]))
    profiles = [scratch / f'probe-{pid}.profraw' for pid in sorted(pids)]
    assert profiles, 'No actual instrumented native-helper process was observed'
    records = []
    unavailable = []
    usable = []
    for profile in profiles:
        if not profile.exists():
            unavailable.append({'file': profile.name,
                'reason': 'No LLVM profile materialized for this observed process; no coverage inferred. Startup/pressure observations remain in the raw attempt.'})
            continue
        result = subprocess.run(['xcrun', 'llvm-profdata', 'show', str(profile)], capture_output=True, text=True)
        assert result.returncode == 0, (profile.name, result.stderr)
        usable.append(profile)
        records.append({'file': profile.name, 'sha256': sha(profile), 'bytes': profile.stat().st_size})
        with gzip.open(out / (profile.name + '.gz'), 'wb') as target:
            target.write(profile.read_bytes())
    merged = scratch / 'native-final.profdata'
    assert usable, 'No valid native profile'
    subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, usable), '-o', str(merged)], check=True)
    raw = subprocess.check_output(['xcrun', 'llvm-cov', 'export', str(binary), '-instr-profile=' + str(merged),
                                   '-format=lcov', 'Sources/TypefluxSemanticHelper/main.swift'], text=True)
    values = {int(line[3:].split(',')[0]): int(line[3:].split(',')[1])
              for line in raw.splitlines() if line.startswith('DA:')}
    diff = subprocess.check_output(['git', 'diff', '--unified=0', '8da72f495dd91295151cf931da71007e33b7fb24',
                                   '--', 'Sources/TypefluxSemanticHelper/main.swift'], text=True)
    changed = set()
    for line in diff.splitlines():
        match = re.match(r'@@ .*\+(\d+)(?:,(\d+))? @@', line)
        if match:
            start, count = int(match[1]), int(match[2] or 1)
            changed.update(range(start, start + count))
    lines = {line: count for line, count in values.items() if line in changed}
    covered = sum(count > 0 for count in lines.values())
    assert lines and covered / len(lines) >= 0.70
    report = {'baseline': '8da72f495dd91295151cf931da71007e33b7fb24',
              'denominator': 'Changed native Swift lines intersected with LLVM LCOV DA records, the existing acceptance convention. Line coverage, not branch coverage or whole-helper coverage.',
              'native_inference_helper': {'covered': covered, 'executable': len(lines), 'lines': lines,
                                          'percent': 100 * covered / len(lines)},
              'application': {'covered': 0, 'executable': 0, 'percent': None},
              'file_helper': {'covered': 0, 'executable': 0, 'percent': None},
              'media_runtime': {'covered': 0, 'executable': 0, 'percent': None},
              'profiles': records, 'unavailable_profiles': unavailable, 'wall_seconds': time.monotonic() - started,
              'source_sha256': built['source_sha256'], 'binary_sha256': built['binary_sha256']}
    (out / 'changed-coverage.json').write_text(json.dumps(report, indent=2) + '\n')
    with gzip.open(out / 'native-final.lcov.gz', 'wb') as target:
        target.write(raw.replace(str(root), '<repo>').encode())
    with gzip.open(out / 'native-final.profdata.gz', 'wb') as target:
        target.write(merged.read_bytes())
    print(json.dumps(report['native_inference_helper']))


if __name__ == '__main__':
    main()
