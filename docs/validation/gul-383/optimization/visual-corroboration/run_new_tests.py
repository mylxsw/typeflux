"""Execute only new methods omitted by the normal helper's hardcoded legacy module filter."""
import json,os,subprocess,sys,time
from pathlib import Path
root=Path.cwd();sys.path.insert(0,str(root/'scripts'));import test_runtime as runtime
out=Path(__file__).resolve().parent;scratch=root/'.build/visual-corroboration'
env=runtime.child_environment();tools=runtime.native_tools(env);bundle=scratch/'TypefluxPackageTests.xctest'
env=runtime.native_environment(bundle,env,tools);label=os.environ.get('GUL405_VALIDATION_LABEL','new');env['LLVM_PROFILE_FILE']=str(scratch/(label+'-%p.profraw'));env['TYPEFLUX_CORROBORATION_EVIDENCE']=str(out)
binary=bundle/'Contents/MacOS/TypefluxPackageTests'
args=[str(tools['swift-testing']),'--test-bundle-path',str(binary),str(binary),'--testing-library','swift-testing','--no-parallel','--filter',sys.argv[1] if len(sys.argv)>1 else '^GUL405CorroborationTests\\.SemanticImageCorroboration(Service)?Tests/']
start=time.monotonic();r=subprocess.run(args,env=env,cwd=root)
(out/(label+'-test-command.json' if label!='new' else ('retry-test-command.json' if len(sys.argv)>1 else 'new-test-command.json'))).write_text(json.dumps(dict(command=args,exit_code=r.returncode,wall_seconds=time.monotonic()-start,scope='Only the failed parameterized method' if len(sys.argv)>1 else '10 previously unexecuted methods only; legacy module filter omitted new module in first pass'),indent=2)+'\n')
raise SystemExit(r.returncode)
