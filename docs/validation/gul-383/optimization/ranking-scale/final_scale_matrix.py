#!/usr/bin/env python3
"""Foreground final-source matrix; stop on failure and preserve every earlier attempt."""
import argparse
import hashlib
import json
import re
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case', type=int, action='append')
parser.add_argument('--tag', default='final-current')
args = parser.parse_args()
root = Path.cwd()
folder = root / 'docs/validation/gul-383/optimization/ranking-scale'
if not re.fullmatch('[a-z0-9-]+', args.tag):
    parser.error('Safe lowercase tag required')
cases = []
for size in [10000, 100000, 1000000]:
    for scenario, real in [(None, False), ('cold-fts', False), ('hot-new-semantic', True)]:
        for label in ['before', 'after']:
            cases.append(dict(size=size, label=label, mode='native', scenario=scenario, real=real,
                              tag=args.tag + ('-coldfts' if scenario == 'cold-fts' else '-real' if real else '')))
    for label in ['before', 'after']:
        cases.append(dict(size=size, label=label, mode='contention', tag=args.tag, scenario=None, real=False))
if args.case and any(index < 0 or index >= len(cases) for index in args.case):
    parser.error('Case index outside the explicit matrix')
selected = [index for index in range(len(cases)) if not args.case or index in args.case]
path = folder / f'matrix-run-{args.tag}.json'
if path.exists():
    parser.error('Use a new tag; preserve previous run metadata: ' + path.name)
manifest = json.loads((folder / 'source-hashes.json').read_text())
source = json.loads((folder / 'final-source-head.json').read_text())['source_commit']
started = time.time()
start = time.monotonic()
results = []
exit_code = None
failure = None


def check_source():
    if any(hashlib.sha256((root / name).read_bytes()).hexdigest() != value for name, value in manifest.items()):
        raise RuntimeError('Production source changed: rebuild before measuring')


def save():
    path.write_text(json.dumps(dict(started_unix=started, wall_seconds=time.monotonic() - start,
        exit_code=exit_code, failure=failure, selected_cases=selected, source_commit=source, cells=results,
        driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        scope='Same pinned models/host, prebuilt Release. Baseline262135 and the declared final source use the same behavioral harness; main integration also includes other UI changes. Native input is a committed NSTextView edit; result rendering uses actual layout/display and accessibility, without a WindowServer result fence. Resource experiments use a separate own-window compositor probe. All failed samples/commands remain. This owner stops on the first failed cell; a new tagged run is required for a retry.'), indent=2) + '\n')


try:
    for index in selected:
        case = cases[index]
        check_source()
        checkout = '.' if case['label'] == 'after' else '.build/baseline-code'
        command = ['python3', str(folder / 'rework_release_runner.py'), '--checkout', checkout,
                   '--mode', case['mode'], '--label', case['label'], '--size', str(case['size']), '--tag', case['tag']]
        if case['scenario']:
            command += ['--scenario', case['scenario']]
        if case['real']:
            command += ['--real-noise']
        if case['mode'] == 'contention':
            command += ['--asr', '.build/asr-assets', '--speech', '.build/asr-assets/speech.wav']
        output = folder / f"matrix-{case['mode']}-{case['label']}-{case['size']}-{case['tag']}"
        if output.exists():
            raise RuntimeError('Use a new tag; preserve previous cell: ' + output.name)
        owner = ['python3', str(folder / 'rework_resource_runner.py'), '--output', str(output), '--'] + command
        print('Cell', index, json.dumps(case), flush=True)
        cell_start = time.monotonic()
        code = subprocess.run(owner).returncode
        results.append(dict(index=index, **case, exit_code=code, wall_seconds=time.monotonic() - cell_start))
        save()
        check_source()
        if code:
            failure = 'Cell failed; remaining cells were not started'
            exit_code = code
            break
    else:
        exit_code = 0
except BaseException as error:
    exit_code = 1
    failure = str(error) or type(error).__name__
    raise
finally:
    if exit_code is None:
        exit_code = 1
    save()
print(json.dumps(dict(exit_code=exit_code, cells=len(results), wall_seconds=time.monotonic() - start)))
raise SystemExit(exit_code)
