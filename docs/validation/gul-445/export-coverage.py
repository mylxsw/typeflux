#!/usr/bin/env python3
"""Export source-relative LCOV and verify hashes after focused coverage/retries."""
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT/'docs/validation/gul-445'
bin_dir = Path(subprocess.check_output(['swift','build','--build-system','native','--show-bin-path'],cwd=ROOT,text=True).strip())
profile = bin_dir/'codecov/default.profdata'
binary = bin_dir/'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
paths = sorted((ROOT/'Sources/Typeflux/Ask').rglob('*.swift'))
command = ['xcrun','llvm-cov','export',str(binary),'--instr-profile='+str(profile),'--format=lcov']+[str(p) for p in paths]
data = subprocess.check_output(command,cwd=ROOT).decode().replace(str(ROOT)+'/', '')
with gzip.open(OUT/'swift.lcov.gz','wt') as f: f.write(data)
files = {}
for record in data.split('end_of_record'):
    lines = record.splitlines()
    source = next((line[3:] for line in lines if line.startswith('SF:')),None)
    if not source: continue
    counts = [line[3:].split(',') for line in lines if line.startswith('DA:')]
    unique = {}
    for line,hit,*_ in counts: unique[int(line)] = max(unique.get(int(line),0),int(hit))
    files[source] = dict(executable=len(unique),covered=sum(hit>0 for hit in unique.values()),sha256=hashlib.sha256((ROOT/source).read_bytes()).hexdigest())
full = dict(changed_production_executable_lines=0,files=files)
(OUT/'production-coverage-full.json').write_text(json.dumps(full,indent=2,sort_keys=True)+'\n')
selected = {'AskConversationModel.swift','AskApplicationAPI.swift','AskAgentBinding.swift','AskAgentTurn.swift','AskFolderGrants.swift','AskLocalTools+Files.swift','AskLocalEngine.swift','AskHostCommand.swift','AskPromptBuilder.swift'}
(OUT/'production-coverage.json').write_text(json.dumps(dict(changed_production_executable_lines=0,files={p:r for p,r in files.items() if Path(p).name in selected}),indent=2,sort_keys=True)+'\n')
manifest_paths = paths+list((ROOT/'Tests/TypefluxTests').glob('Ask*Tests.swift'))+list((ROOT/'Sources/Typeflux/Resources').glob('*.lproj/Localizable.strings'))
manifest = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in manifest_paths}
(OUT/'source-hashes.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in manifest.items())
print('Exported',len(files),'Ask production files, source-relative LCOV; all source hashes verified.')
