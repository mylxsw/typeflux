"""One focused product validation after implementation and self-review."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

root = Path.cwd()
out = Path(__file__).resolve().parent
scope = ('SemanticEmbeddingWorkerTests/(indexingMediaKeepsBudgetThreadLimitsCancellationAndRetirement|.*validated.*)'
         '|SemanticWorkBudgetTests|SemanticBudgetLifecycleTests'
         '|AskFileReaderRetirementTests/testBudgetSignalsRemainInsideTheOwnedChildRetirementBoundary')
env = dict(os.environ)
env.update(TYPEFLUX_COVERAGE_SCRATCH=str(root / '.build/video-frames'),
           TYPEFLUX_GUL405_TEST_FILES=str(out / 'test-files.json'),
           TYPEFLUX_COVERAGE_WRAPPER=str(root / 'docs/validation/gul-383/optimization/download-resume/coverage-swift.sh'))
command = ['make', 'coverage', 'FILTER=' + scope]
with tempfile.TemporaryDirectory(prefix='qos-coverage-', dir=root / '.build') as shim:
    swift = Path(shim) / 'swift'
    swift.write_text('#!/bin/bash\nexec bash "$TYPEFLUX_COVERAGE_WRAPPER" "$@"\n')
    swift.chmod(0o755)
    env['PATH'] = shim + ':' + env['PATH']
    started = time.monotonic()
    with (out / 'coverage.log').open('w') as log:
        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
    record = {'command': command, 'wall_seconds': time.monotonic() - started, 'exit_code': result.returncode,
              'cache': 'Private APFS clone of accepted PR646 build; original cache left untouched'}
    (out / 'coverage-command.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
raise SystemExit(result.returncode)
