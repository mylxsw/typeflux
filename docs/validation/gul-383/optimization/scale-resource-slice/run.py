"""Run only the bounded native scope with private Foundation preferences and caches."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--plan', action='store_true')
parser.add_argument('--suite', action='append')
args = parser.parse_args()
root = Path.cwd()
out = Path(__file__).resolve().parent
sys.path.insert(0, str(root / 'scripts'))
import test_groups

files = json.loads((root / 'docs/validation/gul-383/optimization/media-isolation/read-signals/test-files.json').read_text())
# Keep the verified first-slice closure, including all fixture dependencies.
files.append('SemanticReleaseUISliceTests.swift')
suites = args.suite or ['SemanticNativeLatencyTests', 'SemanticNativeContentionTests', 'SemanticResourceBudgetTests']
test_groups.PROFILES['scale-resource-slice'] = {'files': sorted(set(files)), 'suites': suites}
bin_dir = root / '.build/scale-resource-tools'
bin_dir.mkdir(exist_ok=True)
shim = bin_dir / 'swift'
shim.write_text('#!/usr/bin/env python3\nimport os,sys\nargs=sys.argv[1:]\nif args and args[0] in ["build","test"]: args += ["-c","release","-Xswiftc","-enable-testing"]\nos.execv("/usr/bin/swift",["/usr/bin/swift",*args])\n')
shim.chmod(0o755)
private = root / '.build/validation-private'
(private / 'Library/Caches').mkdir(parents=True, exist_ok=True)
model = root / '.build/semantic/embeddinggemma-2-Q8_0.gguf'
os.environ.update(
    PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
    CFFIXED_USER_HOME=str(private), TYPEFLUX_VALIDATION_PRIVATE_ROOT=str(private),
    TYPEFLUX_SEMANTIC_NATIVE_BENCH_MODEL=str(model), TYPEFLUX_SEMANTIC_CONTENTION_MODEL=str(model),
    TYPEFLUX_SEMANTIC_SHORT_SAMPLES='3', TYPEFLUX_SEMANTIC_SCENARIO='short-hot',
    TYPEFLUX_SEMANTIC_LABEL='gul406-slice2', TYPEFLUX_SEMANTIC_SCALE='100000',
    TYPEFLUX_SEMANTIC_REFERENCE_BUDGET='1',
    TYPEFLUX_RESOURCE_REPORT=str(out / 'resource-on'), TYPEFLUX_RESOURCE_MODEL=str(model),
    TYPEFLUX_RESOURCE_PROJECTOR=str(model),  # Not read by the explicit text-only mode.
    TYPEFLUX_RESOURCE_HELPER=str(root / '.build/semantic/TypefluxSemanticHelper'),
    TYPEFLUX_RESOURCE_PROBE=str(root / '.build/SemanticNativeResponseProbe.app/Contents/MacOS/SemanticNativeResponseProbe'),
    TYPEFLUX_RESOURCE_SECONDS='300', TYPEFLUX_RESOURCE_CONDITION='on', TYPEFLUX_RESOURCE_TEXT_ONLY='1',
    LLVM_PROFILE_FILE=str(root / '.build/scale-resource-helper-%p.profraw'))
command = ['test_groups.py', '--profile', 'scale-resource-slice', '--jobs', '4', '--serial']
for suite in suites:
    command += ['--suite', suite]
if args.plan:
    command += ['--plan']
sys.argv = command
start, wall = time.monotonic(), time.time()
code = test_groups.main()
report = {'command': command, 'started_unix': wall, 'wall_seconds': time.monotonic() - start,
          'exit_code': code, 'closure': sorted(set(files)), 'suites': suites,
          'configuration': 'Release -enable-testing; normal runner source/artifact audit',
          'native_helper': 'Reused first-slice packaged helper, unchanged source',
          'isolation': 'Process-local CFFIXED_USER_HOME, checked by every selected suite before model/UI work'}
name = ('plan' if args.plan else 'run') + '-' + '-'.join(suites)
(out / (name + '.json')).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
raise SystemExit(code)
