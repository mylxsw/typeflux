#!/usr/bin/env python3
"""Run only the approved integrated hot-query cells and one ON window; stop on failure."""
import hashlib,json,os,subprocess,time
from pathlib import Path
r=Path.cwd();h=r/'docs/validation/gul-383/optimization/ranking-scale';out=h/'final-integration-short'
frozen=json.loads((out/'production-frozen.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def check():assert all(sha(r/n)==v for n,v in frozen.items()),'Frozen production source changed'
check();binary=r/'.build/out/Products/Release/TypefluxFocusedTests.xctest/Contents/MacOS/TypefluxFocusedTests'
files=['.build/semantic/TypefluxSemanticHelper','.build/semantic/embeddinggemma-2-Q8_0.gguf','.build/semantic/mmproj-embeddinggemma-2-Q8_0.gguf','.build/SemanticNativeResponseProbe.app/Contents/MacOS/SemanticNativeResponseProbe','Tests/TypefluxTests/SemanticResourceBudgetTests.swift','Tests/TypefluxTests/SemanticNativeContentionTests.swift','Tests/TypefluxTests/SemanticNativeLatencyTests.swift','Tests/TypefluxTests/SemanticLatencyTests.swift','docs/validation/gul-383/optimization/ranking-scale/native_response_probe.swift','docs/validation/gul-383/optimization/ranking-scale/rework_resource_runner.py','docs/validation/gul-383/optimization/ranking-scale/rework_release_runner.py','docs/validation/gul-383/optimization/ranking-scale/darwin_process_metrics.py']
provenance=dict(source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),production_commit='3c3de617b158a09497918afb1b8e5250523a1a91',production_manifest_sha256=sha(out/'production-frozen.json'),binary_sha256=sha(binary),files={n:sha(r/n) for n in files},scope='Frozen integrated product source. Existing prebuilt Release harness, current test-only ON selection and explicit contention fixture rescan. No baseline/cold/million/ranking/product regression run. Query display is native layout/accessibility, not a query compositor fence; ON response probe is an independent own-window WindowServer measurement.')
old=json.loads((h/'resource-after-closeout-300/provenance.json').read_text())
provenance['historical_artifact_matches']={n:provenance['files'][n]==old['files'].get(n) for n in files[:4]}
assert all(provenance['historical_artifact_matches'].values()),'Reused model/helper/probe fingerprint changed'
(out/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
env=dict(os.environ)
for k in ['TYPEFLUX_SEMANTIC_ENTRY','TYPEFLUX_SEMANTIC_SCENARIO','TYPEFLUX_SEMANTIC_TRACE','TYPEFLUX_SEMANTIC_DENY_DOCUMENT','TYPEFLUX_SEMANTIC_REAL_NOISE','TYPEFLUX_SEMANTIC_CONTENTION_ASR','TYPEFLUX_SEMANTIC_CONTENTION_SPEECH']:env.pop(k,None)
cases=[('resource-on','resource','final-short-on',None),('hot-body','native','final-short-fts','fts-cache'),('hot-semantic','native','final-short-semantic','hot-new-semantic'),('index-contention','contention','final-short-contention',None)]
results=[];started=time.time();begin=time.monotonic();code=1
try:
 for name,mode,tag,scenario in cases:
  check();assert sha(binary)==provenance['binary_sha256'],'Harness changed during measurement'
  command=['python3',str(h/'rework_release_runner.py'),'--checkout','.', '--mode',mode,'--label','after','--size','100000','--tag',tag]
  if scenario:command+=['--scenario',scenario]
  command=['python3',str(h/'rework_resource_runner.py'),'--output',str(out/(name+'-resources')),'--']+command
  current=dict(env)
  if mode=='resource':current.update(TYPEFLUX_RESOURCE_SECONDS='300',TYPEFLUX_RESOURCE_CONDITION='on')
  print(name,flush=True);start=time.monotonic();wall=time.time()
  with (out/(name+'-owner.log')).open('w') as log:done=subprocess.run(command,env=current,stdout=log,stderr=subprocess.STDOUT)
  code=done.returncode
  if code == 0 and mode in ['native','contention']:
   artifact=h/(f'native-after-100000-{tag}.json' if mode=='native' else f'contention-after-{tag}-100000.json')
   report=json.loads(artifact.read_text())
   expected=200 if mode=='native' else 400
   assert artifact.stat().st_mtime >= wall-1 and report.get('complete') and not report.get('failed_body_samples'), 'Missing or incomplete query results'
   assert len(report['rows'])==expected and all(x.get('input_to_draw_ms') is not None for x in report['rows']), 'Missing requested query samples'
  results.append(dict(case=name,command=command,started_unix=wall,wall_seconds=time.monotonic()-start,exit_code=code,tag=tag,mode=mode))
  (out/'commands.json').write_text(json.dumps(dict(started_unix=started,wall_seconds=time.monotonic()-begin,cases=results,exit_code=code),indent=2)+'\n')
  check()
  if code:print('Stopped at failed case',name,flush=True);break
finally:
 (out/'commands.json').write_text(json.dumps(dict(started_unix=started,wall_seconds=time.monotonic()-begin,cases=results,exit_code=code),indent=2)+'\n')
print(json.dumps(dict(exit_code=code,completed_cases=len(results),wall_seconds=time.monotonic()-begin)));raise SystemExit(code)
