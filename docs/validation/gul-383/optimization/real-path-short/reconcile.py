#!/usr/bin/env python3
"""Freeze exact sources/tools and identify the limits of accepted evidence reuse."""
import gzip, hashlib, json, subprocess
from pathlib import Path

root = Path.cwd()
out = Path(__file__).resolve().parent


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


files = git('ls-files', 'Sources', 'Tests', 'Packages', 'scripts', 'Package.swift', 'Package.resolved').splitlines()
(out / 'current-inputs.json').write_text(json.dumps({n: sha(root / n) for n in files if (root / n).is_file()}, indent=2) + '\n')
old = 'dcae50561a637082ffc8710f06a9d99924cd3f5c'
paths = git('ls-tree', '-r', '--name-only', old, 'Sources/Typeflux/Ask/QuickResults/Semantic',
    'Sources/TypefluxSemanticHelper', 'scripts/semantic-no-logits.patch').splitlines()
unchanged, changed = [], []
for name in paths:
    prior = subprocess.check_output(['git', 'show', old + ':' + name])
    path = root / name
    (unchanged if path.is_file() and hashlib.sha256(prior).hexdigest() == sha(path) else changed).append(name)
(out / 'gul404-source-reuse.json').write_text(json.dumps({'accepted_merge': old, 'current_base': git('rev-parse', 'HEAD'),
    'unchanged': unchanged, 'changed': changed,
    'scope': 'Old fixed quality retains its original labels/denominators and exact model/helper. Calibration is unchanged. Changed extraction, provenance, snippets and lifecycle do not inherit a new-version full quality or latency conclusion.'}, indent=2) + '\n')
with gzip.open(out / 'accepted-to-main.patch.gz', 'wt') as stream:
    stream.write(git('diff', '689225d8a83747fde8a5e5f7cfa6151892df6f23', 'HEAD', '--', 'Sources', 'Tests') + '\n')
records = []
for number in [595, 598, 601, 605, 607, 610, 614, 620, 622, 624, 628, 633, 636, 638, 642, 645, 646]:
    # Verify the actual local main merge ancestry; platform state was read separately once.
    commits = git('log', '--merges', '--format=%H', '--grep=Merge pull request #' + str(number) + ' ', 'HEAD').splitlines()
    assert len(commits) == 1, (number, commits)
    subprocess.run(['git', 'merge-base', '--is-ancestor', commits[0], 'HEAD'], check=True)
    records.append({'pr': number, 'merge': commits[0], 'ancestor_of_base': True})
(out / 'merged-scope.json').write_text(json.dumps(records, indent=2) + '\n')
tools = ['build_probe.py', 'run_probe.py', 'real_path_probe.swift', 'reconcile.py', 'summarize.py']
other = ['docs/validation/gul-383/optimization/ranking-scale/native_response_probe.swift',
    'docs/validation/gul-383/optimization/ranking-scale/rework_resource_runner.py',
    'docs/validation/gul-383/optimization/ranking-scale/darwin_process_metrics.py']
(out / 'tool-fingerprints.json').write_text(json.dumps({**{name: sha(out / name) for name in tools},
    **{name: sha(root / name) for name in other}}, indent=2) + '\n')
(out / 'environment.json').write_text(json.dumps({'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
    'memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
    'base': git('rev-parse', 'HEAD'), 'configuration': 'Reused PR646 Debug objects; real helper uses its frozen Release build'}, indent=2) + '\n')
print(json.dumps({'current_inputs': len(files), 'gul404_unchanged': len(unchanged), 'gul404_changed': len(changed), 'merged_prs': len(records)}))
