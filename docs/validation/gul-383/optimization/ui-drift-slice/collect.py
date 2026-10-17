"""Collect final command evidence without repeating successful tests."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
out = Path(__file__).resolve().parent
subprocess.run(['python3', str(out / 'finalize.py')], check=True)
subprocess.run(['git', 'diff', '--check'], check=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean(value):
    return value.replace(str(root), '<repository>')


logs = {'plan-initial.log.gz': '.build/ui-drift-plan.log',
        'plan-retry.log.gz': '.build/ui-drift-plan-retry.log',
        'execution-initial.log.gz': '.build/ui-drift-execution.log',
        'execution-lifecycle-retry.log.gz': '.build/ui-drift-native-retry.log',
        'execution-height-retry.log.gz': '.build/ui-drift-height-retry.log',
        'quality-audit-initial.log.gz': '.build/quality-audit.log',
        'quality-audit-retry.log.gz': '.build/quality-audit-retry.log'}
for name, source in logs.items():
    (out / name).write_bytes(gzip.compress(clean((root / source).read_text()).encode(), mtime=0))

commands = ['cache-preparation.json', 'plan-initial-failed.json',
            'plan-SemanticReleaseUISliceTests-AskLauncherPlacementTests.json', 'run-initial-failed.json',
            'before-height-repair/run-SemanticReleaseUISliceTests.json',
            'run-SemanticReleaseUISliceTests.json', 'package-refresh.json', 'quality-audit-command.json']
(out / 'timings.json').write_text(json.dumps({name: {key: value for key, value in
    json.loads((out / name).read_text()).items() if key in ['command', 'wall_seconds', 'exit_code']}
    for name in commands}, indent=2) + '\n')

syntax = []
for path in sorted(out.glob('*.py')):
    compile(path.read_text(), str(path), 'exec')
    syntax.append(path.name)
bundle = root / '.build/candidate/Typeflux.app'
manifest = json.loads((out / 'bundle-files.json').read_text())
assert all(sha(bundle / name) == expected['sha256'] for name, expected in manifest.items())
processes = []
for line in subprocess.check_output(['ps', '-Ao', 'pid=,comm=,args='], text=True).splitlines():
    if str(root / '.build') in line and any(name in line for name in
        ['TypefluxSemanticHelper', 'TypefluxMediaHelper', 'swiftpm-testing-helper', 'xctest']):
        parts = line.strip().split(None, 2)
        processes.append({'pid': int(parts[0]), 'executable': clean(parts[1])})
assert not processes, processes
assert not list(root.glob('gul406-ui-runtime-*'))
(out / 'cleanup.json').write_text(json.dumps({'remaining_owned_processes': processes,
    'generated_corpus_roots_remaining': 0, 'scope': 'Exact task build-root helper/test products only; no global executable-name termination.'}, indent=2) + '\n')
checks = {'swift_lint_changed_file': json.loads((out / 'lint-height.json').read_text())['diagnostics'] == [],
          'python_syntax': syntax, 'diff_check_exit_code': 0, 'bundle_files_verified': len(manifest),
          'placement_tests_passed': 14, 'icon_tests_passed': 2,
          'final_native_method_exit_code': json.loads((out / 'run-SemanticReleaseUISliceTests.json').read_text())['exit_code'],
          'changed_production_lines': {name: {'covered': 0, 'executable': 0, 'status': 'N/A'}
              for name in ['app', 'file-worker', 'native-helper', 'media-runtime']},
          'acceptance': 'Partial GUL-406 handoff. Fixed 306 recall fails; current 750-point main geometry unmeasured. No threshold waiver or GUL-407 start.'}
assert checks['swift_lint_changed_file'] and checks['final_native_method_exit_code'] == 0
(out / 'final-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
environment = {'machine': os.uname().machine, 'configuration': 'Release -enable-testing',
               'macos': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
               'cpu': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
               'physical_memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
               'samples': '50 existing text documents; 3 samples per entry/group; no 100k/resource rerun'}
(out / 'environment.json').write_text(json.dumps(environment, indent=2) + '\n')
shutil.rmtree(out / '__pycache__', ignore_errors=True)
# Redact runtime checkout prefixes in metadata only; preserve measurements and binary/source hashes.
for path in out.rglob('*'):
    if path.is_file() and path.suffix in ['.json', '.md', '.patch']:
        path.write_text(clean(path.read_text()))
tools = list(out.glob('*.py')) + [root / 'scripts' / name for name in
    ['test_groups.py', 'test_runtime.py', 'test_profiles.py', 'copy_media_helper.sh',
     'copy_inference_helper.sh', 'copy_resource_bundles.sh', 'audit_macho_minos.sh']]
tools += [root / 'Tests/TypefluxTests' / name for name in
    ['SemanticReleaseUISliceTests.swift', 'NativeIconIsolationTests.swift', 'AskLauncherPlacementTests.swift', 'AskAttachmentTests.swift']]
(out / 'tool-manifest.json').write_text(json.dumps({str(path.relative_to(root)): sha(path)
    for path in sorted(tools)}, indent=2) + '\n')
(out / 'evidence-sha256.json').write_text(json.dumps({str(path.relative_to(out)): sha(path)
    for path in sorted(out.rglob('*')) if path.is_file() and path.name != 'evidence-sha256.json'}, indent=2) + '\n')
print(json.dumps(checks))
