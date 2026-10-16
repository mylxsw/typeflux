#!/usr/bin/env python3
"""Own and collect the complete final-sourcefive-minute OFF/ON reference in the foreground."""
import hashlib,json,subprocess,time
from pathlib import Path
r=Path.cwd();(r/'.build/gul404-final-resources.pid').write_text(str(__import__('os').getpid()));h=r/'docs/validation/gul-383/optimization/ranking-scale';folder=h/'resource-after-closeout-300';assert not folder.exists() or not any(folder.iterdir()), 'Preserve previous resource evidence';folder.mkdir(exist_ok=True)
manifest=json.loads((h/'source-hashes.json').read_text());source=json.loads((h/'final-source-head.json').read_text())['source_commit']
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def check():
 assert all(sha(r/name)==value for name,value in manifest.items()),'Source changed; rebuild before measuring'
check();files=['.build/semantic/TypefluxSemanticHelper','.build/semantic/embeddinggemma-2-Q8_0.gguf','.build/semantic/mmproj-embeddinggemma-2-Q8_0.gguf','.build/SemanticNativeResponseProbe.app/Contents/MacOS/SemanticNativeResponseProbe','Tests/TypefluxTests/SemanticResourceBudgetTests.swift','docs/validation/gul-383/optimization/ranking-scale/native_response_probe.swift','docs/validation/gul-383/optimization/ranking-scale/rework_resource_runner.py','docs/validation/gul-383/optimization/ranking-scale/darwin_process_metrics.py','.build/out/Products/Release/TypefluxFocusedTests.xctest/Contents/MacOS/TypefluxFocusedTests']
(folder/'provenance.json').write_text(json.dumps(dict(source_commit=source,condition_seconds=300,files={name:sha(r/name) for name in files},production_manifest_sha256=sha(h/'source-hashes.json'),scope='Final-source prebuilt Release, actual production work budget. Same300-second mixed-file arrival plan per OFF/ON condition and independent own-window WindowServer event-ID probe. No physicalHID/monitor scanout or query-result compositor claim. No owned build, other UI or model benchmark overlaps. Shared external activity sampled, not controlled. Historical1265 long tails retained separately.'),indent=2)+'\n')
command=['python3',str(h/'rework_resource_runner.py'),'--output',str(folder),'--','python3',str(h/'rework_release_runner.py'),'--checkout','.', '--mode','resource','--label','after','--tag','closeout-300'];start=time.monotonic();wall=time.time();code=1;failure=None
try:
 code=subprocess.run(command,env=dict(__import__('os').environ,TYPEFLUX_RESOURCE_SECONDS='300')).returncode;check()
finally:
 (h/'closeout-resource-command.json').write_text(json.dumps(dict(command=command,started_unix=wall,wall_seconds=time.monotonic()-start,exit_code=code),indent=2)+'\n')
raise SystemExit(code)
