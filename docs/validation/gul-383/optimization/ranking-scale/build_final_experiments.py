#!/usr/bin/env python3
"""Build/discover both explicit Release experiment closures without running tests."""
import hashlib, json, os, subprocess, time
from pathlib import Path

r = Path.cwd(); h = r/'docs/validation/gul-383/optimization/ranking-scale'
for label, checkout, files in [('after',r,'rework-release-test-files.json'),
                               ('before',r/'.build/baseline-code','rework-baseline-test-files.json')]:
    env = dict(os.environ, TYPEFLUX_TEST_FILES=(r/'.build'/files).read_text())
    command = ['/usr/bin/swift','test','--configuration','release','--jobs','2','list']
    start = time.monotonic(); wall = time.time()
    with (h/f'final-release-build-{label}.log').open('w') as log:
        result = subprocess.run(command,cwd=checkout,env=env,stdout=log,stderr=subprocess.STDOUT)
    report = dict(command=command,wall_seconds=time.monotonic()-start,started_unix=wall,exit_code=result.returncode,
                  source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=checkout,text=True).strip(),
                  compile_closure=json.loads(env['TYPEFLUX_TEST_FILES']),scope='Build/discovery only, no test execution.')
    (h/f'final-release-build-{label}.json').write_text(json.dumps(report,indent=2)+'\n')
    print(label,report['wall_seconds'],result.returncode,flush=True)
    if result.returncode: raise SystemExit(result.returncode)
