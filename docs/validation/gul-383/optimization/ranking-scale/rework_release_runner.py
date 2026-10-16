#!/usr/bin/env python3
"""Run an already-built Release experiment in the foreground, without compiler overlap."""
import argparse,hashlib,json,os,re,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--checkout',type=Path,required=True);p.add_argument('--mode',choices=['ranking','original','resource','native','contention'],required=True);p.add_argument('--label',choices=['before','after'],required=True);p.add_argument('--size',type=int,default=100000);p.add_argument('--tag',default='rework');p.add_argument('--scenario');p.add_argument('--entry');p.add_argument('--asr',type=Path);p.add_argument('--speech',type=Path);p.add_argument('--real-noise',action='store_true');a=p.parse_args()
if not re.fullmatch('[a-z0-9-]+',a.tag):p.error('safe tag required')
r=a.checkout.resolve();folder=r/'docs/validation/gul-383/optimization/ranking-scale';binary=r/'.build/out/Products/Release/TypefluxFocusedTests.xctest/Contents/MacOS/TypefluxFocusedTests'
if not binary.is_file():p.error('build the exact harness before the timed experiment')
parent=Path(__file__).resolve().parents[5];assets=parent/'.build/semantic';developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());helper=developer/'Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
env=dict(os.environ);env.pop('TYPEFLUX_PROBE_STALL_MS',None);env.update(DYLD_FRAMEWORK_PATH=str(binary.parents[3])+':'+str(developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks'),DYLD_LIBRARY_PATH=str(binary.parents[3])+':'+str(developer/'Platforms/MacOSX.platform/Developer/usr/lib'),TYPEFLUX_SEMANTIC_LABEL=a.label+'-'+a.tag,TYPEFLUX_SEMANTIC_TAG=a.tag,TYPEFLUX_SEMANTIC_SCALE=str(a.size),TYPEFLUX_SEMANTIC_REFERENCE_BUDGET='1',TYPEFLUX_SEMANTIC_NATIVE_BENCH_MODEL=str(assets/'embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_CONTENTION_MODEL=str(assets/'embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_RANKING_COMPARISON='1')
# Native filenames already carry the tag separately; ranking/original filenames use the label.
if a.mode == 'native':env['TYPEFLUX_SEMANTIC_LABEL']=a.label
if a.scenario:env['TYPEFLUX_SEMANTIC_SCENARIO']=a.scenario
if a.entry:env['TYPEFLUX_SEMANTIC_ENTRY']=a.entry
if a.real_noise:env['TYPEFLUX_SEMANTIC_REAL_NOISE']='1'
if a.asr:env['TYPEFLUX_SEMANTIC_CONTENTION_ASR']=str(a.asr.resolve())
if a.speech:env['TYPEFLUX_SEMANTIC_CONTENTION_SPEECH']=str(a.speech.resolve())
resource=folder/('resource-'+a.label+'-'+a.tag);resource.mkdir(exist_ok=True)
for prefix in ['TYPEFLUX_ORIGINAL','TYPEFLUX_RESOURCE']:
 env.update({prefix+'_MODEL':str(assets/'embeddinggemma-2-Q8_0.gguf'),prefix+'_PROJECTOR':str(assets/'mmproj-embeddinggemma-2-Q8_0.gguf'),prefix+'_HELPER':str(assets/'TypefluxSemanticHelper')})
env['TYPEFLUX_RESOURCE_PROBE']=str(parent/'.build/SemanticNativeResponseProbe.app/Contents/MacOS/SemanticNativeResponseProbe')
env['TYPEFLUX_ORIGINAL_CORPUS']=str(parent/'.build/rework-original-corpus');env['TYPEFLUX_RESOURCE_REPORT']=str(resource)
suite={'ranking':'SemanticRankingComparisonTests','original':'SemanticOriginalMediaOracleTests','resource':'SemanticResourceBudgetTests','native':'SemanticNativeLatencyTests','contention':'SemanticNativeContentionTests'}[a.mode]
command=[str(helper),'--test-bundle-path',str(binary),'--testing-library','swift-testing','--no-parallel','--filter',suite];stem='rework-run-'+a.mode+'-'+a.label+'-'+str(a.size)+'-'+a.tag;started=time.time();start=time.monotonic();manifest=json.loads((folder/'source-hashes.json').read_text());sources={n:hashlib.sha256((r/n).read_bytes()).hexdigest() for n in manifest if (r/n).is_file()}
with (folder/(stem+'.log')).open('w') as log:result=subprocess.run(command,cwd=r,env=env,stdout=log,stderr=subprocess.STDOUT)
text=(folder/(stem+'.log')).read_text();code=result.returncode
if not code and not re.search(r'Test run with [1-9][0-9]* tests?',text):code=1
report=dict(command=command,started_unix=started,wall_seconds=time.monotonic()-start,exit_code=code,raw_exit_code=result.returncode,production_sha256=sources,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),scope='Prebuilt Release harness; no compiler or SwiftPM planning inside this command. Actual resource/indexing budget enabled for the current service. Baseline production has no new budget. Frozen ranking is query/store replay, not model/UI end-to-end evidence.')
(folder/(stem+'.json')).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ['production_sha256']}));
if code:print(text[-6000:])
raise SystemExit(code)
