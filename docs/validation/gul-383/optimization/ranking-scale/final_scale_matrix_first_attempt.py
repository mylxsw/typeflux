#!/usr/bin/env python3
"""Foreground-only final-source matrix; completed cells and failed attempts stay separate."""
import argparse, hashlib, json, re, subprocess, time
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--case',type=int,action='append');p.add_argument('--tag',default='final')
a=p.parse_args();root=Path.cwd();h=root/'docs/validation/gul-383/optimization/ranking-scale'
if not re.fullmatch('[a-z0-9-]+',a.tag):p.error('Safe lowercase tag required')
cases=[]
for size in [10000,100000,1000000]:
    for scenario,real in [(None,False),('cold-fts',False),('hot-new-semantic',True)]:
        for label in ['before','after']:
            cases.append(dict(size=size,label=label,mode='native',scenario=scenario,real=real,
                tag=a.tag+('-coldfts' if scenario=='cold-fts' else '-real' if real else '')))
    for label in ['before','after']:
        cases.append(dict(size=size,label=label,mode='contention',tag=a.tag,scenario=None,real=False))
results=[];started=time.monotonic()
if a.case and any(index<0 or index>=len(cases) for index in a.case):p.error('Case index outside the explicit matrix')
manifest=json.loads((h/'source-hashes.json').read_text())
for index,case in enumerate(cases):
    if a.case and index not in a.case:continue
    if any(hashlib.sha256((root/name).read_bytes()).hexdigest()!=value for name,value in manifest.items()):
        raise SystemExit('Production source changed: rebuild before measuring')
    checkout=Path('.') if case['label']=='after' else Path('.build/baseline-code')
    command=['python3',str(h/'rework_release_runner.py'),'--checkout',str(checkout),
             '--mode',case['mode'],'--label',case['label'],'--size',str(case['size']),'--tag',case['tag']]
    if case['scenario']:command+=['--scenario',case['scenario']]
    if case['real']:command+=['--real-noise']
    if case['mode']=='contention':command+=['--asr','.build/asr-assets','--speech','.build/asr-assets/speech.wav']
    output=h/f"matrix-{case['mode']}-{case['label']}-{case['size']}-{case['tag']}"
    if output.exists():raise SystemExit('Use a new tag for a retry; preserve previous cell: '+output.name)
    owner=['python3',str(h/'rework_resource_runner.py'),'--output',str(output),'--']+command
    print('Cell',index,json.dumps(case),flush=True);start=time.monotonic();code=subprocess.run(owner).returncode
    results.append(dict(index=index,**case,exit_code=code,wall_seconds=time.monotonic()-start))
    (h/f'matrix-run-{a.tag}.json').write_text(json.dumps(dict(wall_seconds=time.monotonic()-started,cells=results,
        scope='Same pinned model/host, prebuilt Release. Baseline262135 and final source1265fea7 use identical harnesses; main integration also includes other UI changes. Native input is a committed NSTextView edit; result rendering uses actual layout/display plus accessibility observation, without a WindowServer result fence. Resource experiments have a separate own-window compositor probe. All failed samples remain.'),indent=2)+'\n')
print(json.dumps(results));raise SystemExit(int(any(x['exit_code'] for x in results)))
