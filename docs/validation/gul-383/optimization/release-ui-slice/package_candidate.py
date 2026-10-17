"""Audit an isolated app-only candidate with current packaging copy steps and local signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--helper', type=Path, required=True)
parser.add_argument('--model', type=Path, required=True)
args = parser.parse_args()
root = Path.cwd()
out = root / 'docs/validation/gul-383/optimization/release-ui-slice'
products = root / '.build/out/Products/Release'
app = root / '.build/candidate/Typeflux.app'
assert not app.exists(), 'Use a new isolated candidate directory; do not overwrite another bundle'
started = time.monotonic()
records = []
def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
def run(command, **kwargs):
    before = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    records.append({'command': command, 'exit_code': result.returncode,
                    'wall_seconds': time.monotonic()-before,
                    'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode:
        (out/'package-failure.json').write_text(json.dumps({'records':records,'wall_seconds':time.monotonic()-started},indent=2)+'\n')
        raise RuntimeError(result.stderr)
    return result
native = json.loads((root/'docs/validation/gul-383/optimization/media-isolation/read-signals/product-native-build.json').read_text())
assert sha(root/'Sources/TypefluxSemanticHelper/main.swift') == native['source_sha256']
assert sha(args.helper) == native['binary_sha256']
assert sha(args.model) == '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'
contents = app/'Contents'
resources = contents/'Resources'
(contents/'MacOS').mkdir(parents=True)
resources.mkdir()
shutil.copyfile(root/'app/Info.plist', contents/'Info.plist')
shutil.copyfile(products/'Typeflux', contents/'MacOS/Typeflux')
shutil.copyfile(root/'app/Typeflux.icns', resources/'Typeflux.icns')
for script, target in [('copy_inference_helper.sh', app), ('copy_media_helper.sh', app),
                       ('copy_resource_bundles.sh', resources)]:
    run(['bash',str(root/'scripts'/script),str(products),str(target)])
semantic = resources/'LocalRuntimes/SemanticSearch'
semantic.mkdir(parents=True)
shutil.copyfile(args.helper, semantic/'TypefluxSemanticHelper')
licenses = root/'.build/license-source'
shutil.copyfile(licenses/'LICENSE', semantic/'llama.cpp-LICENSE.txt')
shutil.copytree(licenses/'licenses', semantic/'licenses')
for source, name in [('xxhash/LICENSE','xxhash.txt'),('sha256/LICENSE','sha256.txt'),('rotate-bits/LICENSE.md','rotate-bits.txt')]:
    shutil.copyfile(licenses/'vendor/hash'/source, semantic/'licenses'/name)
shutil.copyfile(root/'Sources/Typeflux/Resources/ThirdPartyNotices-SemanticSearch.txt', semantic/'licenses/semantic-runtime.txt')
executables = [contents/'Helpers/TypefluxInferenceHelper', contents/'Helpers/TypefluxMediaHelper',
               semantic/'TypefluxSemanticHelper', contents/'MacOS/Typeflux']
run(['codesign','--force','--sign','-','--options','runtime',str(contents/'Helpers/swift-transformers_Hub.bundle')])
for path in executables:
    path.chmod(0o755)
    run(['codesign','--force','--sign','-','--options','runtime',str(path)])
run(['codesign','--force','--sign','-','--options','runtime','--entitlements',str(root/'app/TypefluxRuntime.entitlements'),str(app)])
run(['codesign','--verify','--deep','--strict','--verbose=2',str(app)])
run(['codesign','-d','--verbose=4',str(app)])
run(['bash',str(root/'scripts/audit_macho_minos.sh'),str(app),'13.4','arm64'])
for path in executables:
    run(['file',str(path)])
env = {k:v for k,v in os.environ.items() if not any(s in k.upper() for s in ['TOKEN','SECRET','PASSWORD','API_KEY','MULTICA_','CODEX_'])}
env['LLVM_PROFILE_FILE'] = str(root/'.build/candidate/packaged-helper-%p.profraw')
run(['python3',str(root/'scripts/validate_semantic_helper.py'),'--helper',str(semantic/'TypefluxSemanticHelper'),
     '--model',str(args.model),'--report',str(out/'packaged-semantic-execution.json')],env=env,timeout=200)
for path in executables[:2]:
    run([str(path)],input='',env=env,timeout=20)
manifest={str(p.relative_to(app)):{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(app.rglob('*')) if p.is_file()}
(out/'bundle-files.json').write_text(json.dumps(manifest,indent=2)+'\n')
report={'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        'configuration':'Release, -enable-testing; app-only candidate; no optimization flags changed',
        'signing':'Ad-hoc hardened runtime for isolated validation. No Developer ID, notarization, Apple Sign In or distribution claim.',
        'helper_reuse':{'pre_sign_sha256':native['binary_sha256'],'source_sha256':native['source_sha256'],
                       'compiler':'swiftc -O with retained coverage instrumentation; pinned llama.cpp archive'},
        'hardware':subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip(),
        'memory_bytes':int(subprocess.check_output(['sysctl','-n','hw.memsize'],text=True)),
        'os':platform.platform(),'swift':subprocess.check_output(['swift','--version'],text=True).strip(),
        'version':plistlib.loads((contents/'Info.plist').read_bytes()).get('CFBundleShortVersionString'),
        'records':records,'wall_seconds':time.monotonic()-started,'file_count':len(manifest)}
(out/'package.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='records'}))
