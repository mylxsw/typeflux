import hashlib, json, os, subprocess, sys, time, gzip
from pathlib import Path

root = Path.cwd() / 'typeflux'
dev = Path('/Users/mylxsw/multica_workspaces_desktop-api.multica.ai/gulu-bf089d178fd3/gul-405-77cb6039f673/workdir/typeflux')
proof = root / 'docs/validation/gul-383/optimization/video-frames'
out = root / '.build/arch-gul405-video'
out.mkdir(parents=True, exist_ok=True)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
report = {'head': subprocess.check_output(['git','rev-parse','HEAD'], cwd=root,text=True).strip()}
assert report['head'] == 'f9c7aed270e7d4a399d487d5081345907933a2ad'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=dev,text=True).strip() == report['head']
for name, folder in [('source-fingerprints',root),('source-fingerprints-dev',dev),('production-objects',dev),('binary-sha256',dev)]:
    manifest = 'source-fingerprints' if name.endswith('-dev') else name
    entries = json.loads((proof / (manifest+'.json')).read_text())
    bad = [p for p,h in entries.items() if not (folder/p).is_file() or sha(folder/p)!=h]
    report[name] = {'count': len(entries), 'mismatches':bad}
    assert not bad, (name,bad)
tools = json.loads((proof/'tool-binaries.json').read_text())
assert all(sha(Path(v['path'])) == v['sha256'] for v in tools.values())
report['tool_binaries'] = len(tools)
profiles=json.loads((proof/'profile-inputs.json').read_text())
assert all(hashlib.sha256(gzip.decompress((proof/'raw-profiles'/(p+'.gz')).read_bytes())).hexdigest()==v['sha256'] for p,v in profiles.items())
report['profiles'] = len(profiles)
artifacts = subprocess.check_output(['git','ls-files','docs/validation/gul-383/optimization/video-frames'], cwd=root,text=True).splitlines()
report['evidence'] = {p:sha(root/p) for p in artifacts}
(out/'fingerprint-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='evidence'}),flush=True)
sys.path.insert(0,str(root/'scripts'))
import test_runtime
env=os.environ.copy()
native=test_runtime.native_tools(env)
binary=dev/next(iter(json.loads((proof/'binary-sha256.json').read_text())))
env=test_runtime.native_environment(binary.parent.parent.parent,env,native)
env['LLVM_PROFILE_FILE']=str(out/'independent-%p.profraw')
env['TYPEFLUX_GUL405_EVIDENCE']=str(out)
cmd=[str(native['swift-testing']),'--test-bundle-path',str(binary),str(binary),'--testing-library','swift-testing','--no-parallel','--filter','SemanticVideoFrameTests']
start=time.monotonic()
with (out/'independent.log').open('w') as log:
    result=subprocess.run(cmd,cwd=dev,env=env,stdout=log,stderr=subprocess.STDOUT)
timing={'command':cmd,'exit_code':result.returncode,'wall_seconds':time.monotonic()-start,'builds':0,'retries':0}
(out/'independent.json').write_text(json.dumps(timing,indent=2)+'\n')
print(json.dumps(timing),flush=True)
print((out/'independent.log').read_text()[-6000:])
assert result.returncode==0
