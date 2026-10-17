"""Run one explicit native suite through the normal runner against Release products."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--model', type=Path, required=True)
args = parser.parse_args()
root = Path.cwd()
out = Path(__file__).resolve().parent
sys.path.insert(0, str(root/'scripts'))
import test_groups
import test_runtime
files = json.loads((root/'docs/validation/gul-383/optimization/media-isolation/read-signals/test-files.json').read_text())
files.append('SemanticReleaseUISliceTests.swift')
assert all((root/'Tests/TypefluxTests'/name).is_file() for name in files)
test_groups.PROFILES['release-ui-slice'] = {'files': sorted(set(files)), 'suites':['SemanticReleaseUISliceTests']}
# The normal audited runner has a Debug-path convention. Keep its scope/discovery,
# execution and input fingerprint checks, while selecting Release in this local shim.
bin_dir = root/'.build/release-ui-tools'
bin_dir.mkdir(exist_ok=True)
shim = bin_dir/'swift'
shim.write_text('#!/usr/bin/env python3\nimport os,sys\nargs=sys.argv[1:]\nif args and args[0] in ["build","test"]: args += ["-c","release","-Xswiftc","-enable-testing"]\nos.execv("/usr/bin/swift",["/usr/bin/swift",*args])\n')
shim.chmod(0o755)
debug = root/'.build/debug'
if debug.is_symlink():
    assert debug.resolve() == (root/'.build/out/Products/Release').resolve()
else:
    assert not debug.exists()
    debug.symlink_to('out/Products/Release', target_is_directory=True)
os.environ.update(PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
                  TYPEFLUX_RELEASE_UI_OUTPUT=str(out),
                  TYPEFLUX_RELEASE_UI_APP=str(root/'.build/candidate/Typeflux.app'),
                  TYPEFLUX_RELEASE_UI_MODEL=str(args.model.resolve()),
                  LLVM_PROFILE_FILE=str(root/'.build/candidate/native-ui-helper-%p.profraw'))
command=['test_groups.py','--profile','release-ui-slice','--suite','SemanticReleaseUISliceTests','--jobs','4','--serial']
sys.argv = command
start = time.monotonic()
with (out/'native-ui-run.log').open('w') as log:
    saved_out, saved_err = os.dup(1), os.dup(2)
    try:
        sys.stdout.flush();sys.stderr.flush()
        os.dup2(log.fileno(),1);os.dup2(log.fileno(),2)
        code = test_groups.main()
        sys.stdout.flush();sys.stderr.flush()
    finally:
        os.dup2(saved_out,1);os.dup2(saved_err,2);os.close(saved_out);os.close(saved_err)
report={'command':command,'release_swift_flags':['-c','release','-Xswiftc','-enable-testing'],
        'closure':sorted(set(files)),'exit_code':code,'wall_seconds':time.monotonic()-start,
        'scope':'One explicit suite; normal runner discovery and source/artifact verification. Release path shim only.'}
(out/'native-ui-run.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
raise SystemExit(code)
