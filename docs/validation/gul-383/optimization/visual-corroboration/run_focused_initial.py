"""Run a fixed focused scope through the repository's native test discovery/execution helpers."""
import json,os,re,sys,time,hashlib
from pathlib import Path
root=Path.cwd();sys.path.insert(0,str(root/'scripts'))
import test_runtime as runtime
import test_groups as groups
out=Path(__file__).resolve().parent;scratch=root/'.build/visual-corroboration'
started=time.monotonic();env=runtime.child_environment();env['TYPEFLUX_CORROBORATION_EVIDENCE']=str(out)
env['LLVM_PROFILE_FILE']=str(scratch/'focused-%p.profraw')
tools=runtime.native_tools(env);bundle=scratch/'TypefluxPackageTests.xctest'
env=runtime.native_environment(bundle,env,tools)
discovery=runtime.discover(bundle,tools,env,root,scratch)
(out/'discovery.txt').write_text(discovery)
suites=['SemanticImageCorroborationTests','SemanticImageCorroborationServiceTests','SemanticSearchRankingTests','SemanticScoreCalibrationTests','SemanticLexicalSearchTests']
selected={s for s in discovery.splitlines() if any(s.split('/')[0].split('.')[-1]==suite for suite in suites)}
assert selected and all(any(suite in s for s in selected) for suite in suites)
(out/'selected-tests.json').write_text(json.dumps(sorted(selected),indent=2)+'\n')
print('Selected methods',len(selected),flush=True)
status=runtime.run_native('serial',selected,1,bundle,tools,env,lambda cases: groups.test_filter(cases,set(discovery.splitlines())),root,set(discovery.splitlines()))
(out/'test-command.json').write_text(json.dumps(dict(exit_code=status,wall_seconds=time.monotonic()-started,selected_methods=len(selected),command=sys.argv),indent=2)+'\n')
raise SystemExit(status)
