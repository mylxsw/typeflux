#!/usr/bin/env python3
"""Run the declared focused coverage scope, preserving discovery instrumentation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--filter', default='SemanticVideoAudioTests|SemanticAudioWindowTests|SemanticMediaIndexTests|AskMediaLocationTests|AskFilePreviewLoaderTests')
parser.add_argument('--name', default='coverage-run')
args = parser.parse_args()
root = Path.cwd()
evidence = Path(__file__).resolve().parent
env = os.environ.copy()
env['TYPEFLUX_COVERAGE_SCRATCH'] = str(root / '.build/video-frames')
env['TYPEFLUX_GUL405_TEST_FILES'] = str(evidence / 'test-files.json')

env['TYPEFLUX_COVERAGE_WRAPPER'] = str(evidence / 'coverage-swift.sh')
if not args.filter:
    raise SystemExit('Explicit nonempty FILTER required')
command = ['make', 'coverage', 'FILTER=' + args.filter]
with tempfile.TemporaryDirectory(prefix='video-frame-coverage-', dir=root / '.build') as shim:
    swift = Path(shim) / 'swift'
    swift.write_text('#!/bin/bash\nexec bash "$TYPEFLUX_COVERAGE_WRAPPER" "$@"\n')
    swift.chmod(0o755)
    env['PATH'] = shim + ':' + env['PATH']
    start = time.monotonic()
    with (evidence / (args.name + '.log')).open('w') as output:
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT)
    record = {'command': command, 'wall_seconds': time.monotonic() - start, 'exit_code': result.returncode}
    (evidence / (args.name + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
raise SystemExit(result.returncode)
