#!/usr/bin/env python3
"""Retry only the original extraction oracle after correcting supported WAV fixtures."""
import hashlib,json,os,shutil,subprocess,time
from pathlib import Path
r=Path.cwd();(r/'.build/gul404-complete-original.pid').write_text(str(__import__('os').getpid()));h=r/'docs/validation/gul-383/optimization/ranking-scale';base=r/'.build/baseline-code';bh=base/'docs/validation/gul-383/optimization/ranking-scale';target=h/'complete-original-commands.json';assert not target.exists();commands=[];start=time.monotonic()
def run(command,env=None,cwd=r):
 begun=time.monotonic();code=subprocess.run(command,env=env,cwd=cwd).returncode;commands.append(dict(command=command,exit_code=code,wall_seconds=time.monotonic()-begun));target.write_text(json.dumps(dict(commands=commands,wall_seconds=time.monotonic()-start),indent=2)+'\n');assert code==0, 'Preserve failure and fix before retry'
manifest=json.loads((h/'source-hashes.json').read_text());assert all(hashlib.sha256((r/n).read_bytes()).hexdigest()==v for n,v in manifest.items())
run(['python3',str(h/'prepare_original_media.py'),'--assets',str(r/'.build/rework-original-corpus')])
shutil.copy2(r/'Tests/TypefluxTests/SemanticOriginalMediaOracleTests.swift',base/'Tests/TypefluxTests/SemanticOriginalMediaOracleTests.swift')
for label in ['before','after']:
 for ext in ['json','log']:
  old=h/f'final-release-build-{label}.{ext}';copy=h/f'final-query-release-build-{label}.{ext}'
  if not copy.exists():shutil.copy2(old,copy)
run(['python3',str(h/'build_final_experiments.py')])
for label,checkout in [('before',base),('after',r)]:
 env=dict(os.environ,TYPEFLUX_ORIGINAL_CPU='1' if label=='after' else '0')
 run(['python3',str(h/'rework_release_runner.py'),'--checkout',str(checkout),'--mode','original','--label',label,'--tag','complete-final'],env=env)
 if label=='before':
  for name in [f'rework-original-{label}-complete-final.json',f'rework-run-original-{label}-100000-complete-final.json',f'rework-run-original-{label}-100000-complete-final.log']:shutil.copy2(bh/name,h/name)
(h/'complete-original-provenance.json').write_text(json.dumps(dict(source_commit=json.loads((h/'final-source-head.json').read_text())['source_commit'],harness_sha256=hashlib.sha256((r/'Tests/TypefluxTests/SemanticOriginalMediaOracleTests.swift').read_bytes()).hexdigest(),scope='Production sources match the pinnedfinal-source-head.json, including launcher-home permission coalescing. Oracle fixture completeness and audio timestamp validation have dedicated checks. Source8bc incomplete-fixture attempts and failed128.42ms UI candidate remain historical. Native matrix and complete-original/resource executable fingerprints are recorded separately; all final entries must match the same production source manifest. Each executable has its own reported SHA. GPU baseline/CPU current index the same75text+13MOV+12WAV; all200 original queries and25unsupported scanned targets remain.'),indent=2)+'\n')
print(json.dumps(dict(commands=len(commands),wall_seconds=time.monotonic()-start)))
