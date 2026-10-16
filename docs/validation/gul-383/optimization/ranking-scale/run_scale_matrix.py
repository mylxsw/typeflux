#!/usr/bin/env python3
"""Foreground Release benchmark runner, with descendant RSS and complete command timing."""
import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--checkout', type=Path, required=True)
parser.add_argument('--label', choices=['before', 'after'], required=True)
parser.add_argument('--size', type=int, choices=[10000, 100000, 1000000], default=100000)
parser.add_argument('--mode', choices=['build', 'native', 'contention', 'ranking'], required=True)
parser.add_argument('--asr', type=Path)
parser.add_argument('--speech', type=Path)
parser.add_argument('--entry', choices=['mixed', 'file-mode'])
parser.add_argument('--scenario', choices=['cold', 'cold-fts', 'fts-cache', 'semantic-cache', 'hot-new-semantic', 'index-writer'])
parser.add_argument('--tag')
parser.add_argument('--trace', action='store_true')
parser.add_argument('--deny-document', action='store_true')
parser.add_argument('--real-noise', action='store_true')
args = parser.parse_args()
if bool(args.asr) != bool(args.speech):
    parser.error("--asr and --speech must be supplied together")
if (args.entry or args.scenario) and (args.mode != 'native' or not args.tag):
    parser.error('Narrow native retries require --mode native and a unique --tag')
if args.deny_document and (args.mode != 'native' or not args.tag):
    parser.error('Permission-denial harness verification requires native mode and a unique tag')
if args.real_noise and (args.mode != 'native' or not args.tag):
    parser.error('Real-model background-vector probes require native mode and a unique tag')
if args.tag and not re.fullmatch(r'[a-z0-9-]+', args.tag):
    parser.error('--tag permits lowercase letters, digits and hyphens')
root = args.checkout.resolve()
folder = root / 'docs/validation/gul-383/optimization/ranking-scale'
folder.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
env.update(TYPEFLUX_TEST_FILES=json.dumps(['ExclusiveUIStateTrait.swift', 'SemanticLatencyTests.swift',
    'SemanticNativeLatencyTests.swift', 'SemanticNativeContentionTests.swift', 'SemanticRankingComparisonTests.swift',
    'AskConversationTests.swift', 'AskAppSearchTests.swift', 'AskFileSearchTestSupport.swift', 'SettingsBehaviorTestSupport.swift']),
    TYPEFLUX_SEMANTIC_NATIVE_BENCH_MODEL=str(root / '.build/semantic/embeddinggemma-2-Q8_0.gguf'),
    TYPEFLUX_SEMANTIC_CONTENTION_MODEL=str(root / '.build/semantic/embeddinggemma-2-Q8_0.gguf'),
    TYPEFLUX_SEMANTIC_LABEL=(args.label + ("-" + args.tag if args.mode == "ranking" and args.tag else "")), TYPEFLUX_SEMANTIC_SCALE=str(args.size), TYPEFLUX_SEMANTIC_RANKING_COMPARISON='1')
if args.deny_document:
    env['TYPEFLUX_SEMANTIC_DENY_DOCUMENT'] = '1'
if args.real_noise:
    env['TYPEFLUX_SEMANTIC_REAL_NOISE'] = '1'
if args.trace:
    env['TYPEFLUX_SEMANTIC_TRACE'] = '1'
if args.entry:
    env['TYPEFLUX_SEMANTIC_ENTRY'] = args.entry
if args.scenario:
    env['TYPEFLUX_SEMANTIC_SCENARIO'] = args.scenario
if args.tag:
    env['TYPEFLUX_SEMANTIC_TAG'] = args.tag
if args.asr:
    env['TYPEFLUX_SEMANTIC_CONTENTION_ASR'] = str(args.asr.resolve())
if args.speech:
    env['TYPEFLUX_SEMANTIC_CONTENTION_SPEECH'] = str(args.speech.resolve())
command = ['/usr/bin/swift', 'test', '--configuration', 'release', '--jobs', '4']
if args.mode == 'build':
    command += ['list']
else:
    command += ['--filter', {'native':'SemanticNativeLatencyTests', 'contention':'SemanticNativeContentionTests', 'ranking':'SemanticRankingComparisonTests'}[args.mode]]
suffix = '-' + args.tag if args.tag else ''
stem = f'{args.mode}-{args.label}-{args.size}{suffix}'
def host_swap():
    try:
        return subprocess.check_output(['/usr/sbin/sysctl', 'vm.swapusage'], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return None

started = time.monotonic()
started_wall = time.time()
harness_sources = {
    name: hashlib.sha256((root / 'Tests/TypefluxTests' / name).read_bytes()).hexdigest()
    for name in ['SemanticNativeLatencyTests.swift', 'SemanticNativeContentionTests.swift', 'SemanticLatencyTests.swift']
}
source_manifest = json.loads((folder / 'source-hashes.json').read_text())
production_sources = {
    name: hashlib.sha256((root / name).read_bytes()).hexdigest()
    for name in source_manifest
    if (root / name).is_file()
}
swap_before, free_disk_before = host_swap(), shutil.disk_usage(root).free
samples = []
with (folder / (stem + '.log')).open('w') as log:
    process = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
    while process.poll() is None:
        listing = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,%cpu=,comm='], text=True)
        parsed = [line.split(maxsplit=4) for line in listing.splitlines()]
        parsed = [row for row in parsed if len(row) == 5]
        children = {process.pid}
        while True:
            descendants = children | {int(pid) for pid, parent, _, _, _ in parsed if int(parent) in children}
            if descendants == children:
                break
            children = descendants
        relevant = {}
        for pid, _, rss, _, name in parsed:
            name = Path(name).name
            if int(pid) in children and name in {'swiftpm-testing-helper', 'xctest', 'TypefluxPackageTests', 'TypefluxFocusedTests', 'Typeflux', 'TypefluxSemanticHelper', 'sherpa-onnx-offline'}:
                relevant.setdefault(name, []).append(int(rss) * 1024)
        external_compiler_cpu = sum(float(cpu) for pid, _, _, cpu, name in parsed
                                    if int(pid) not in children and Path(name).name in {'swift-frontend', 'clang', 'swiftpm-testing-helper', 'xctest'})
        if relevant or args.mode != 'build':
            samples.append(dict(seconds=time.monotonic()-started, rss_bytes=relevant,
                                external_compiler_or_test_cpu_percent=external_compiler_cpu))
        time.sleep(.5)
    code = process.wait()
validation_error = None
if code == 0:
    transcript = (folder / (stem + '.log')).read_text()
    if args.mode == 'build':
        if not all(name in transcript for name in ['SemanticNativeLatencyTests', 'SemanticNativeContentionTests', 'SemanticRankingComparisonTests']):
            validation_error = 'Expected benchmark suites were absent from test discovery'
    else:
        if not re.search(r'Test run with [1-9][0-9]* tests?', transcript):
            validation_error = 'No Swift Testing execution summary was found'
        outputs = [folder / f'{args.mode}-{args.label}-{args.size}{suffix}.json'] if args.mode != 'ranking' else [folder / ('ranking-' + env['TYPEFLUX_SEMANTIC_LABEL'] + '-' + fixture + '.json') for fixture in ['final-holdout', 'unseen-query', 'rework-frozen']]
        for output in outputs:
            if not output.exists() or output.stat().st_mtime < started_wall - 1:
                validation_error = 'The selected benchmark did not write a fresh result artifact'
    if validation_error:
        code = 1
report = dict(command=command, label=args.label, mode=args.mode, size=args.size, exit_code=code,
              wall_seconds=time.monotonic()-started, sample_period_seconds=.5, samples=samples, validation_error=validation_error,
              started_monotonic_seconds=started, started_at_unix=started_wall, finished_at_unix=time.time(),
              host_swap_before=swap_before, host_swap_after=host_swap(),
              free_disk_bytes_before=free_disk_before, free_disk_bytes_after=shutil.disk_usage(root).free,
              rss_definition='Descendant ps resident pages in bytes; compilers excluded. Summed RSS double-counts shared pages.')
binary = root / '.build/out/Products/Release/TypefluxFocusedTests.xctest/Contents/MacOS/TypefluxFocusedTests'
report['harness_sources_sha256_at_start'] = harness_sources
report['production_sources_sha256_at_start'] = production_sources
report['test_binary_sha256_after_command'] = hashlib.sha256(binary.read_bytes()).hexdigest() if binary.exists() else None
(folder / ('run-' + stem + '.json')).write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({key:value for key,value in report.items() if key!='samples'}))
if code:
    print((folder / (stem + '.log')).read_text()[-5000:])
raise SystemExit(code)
