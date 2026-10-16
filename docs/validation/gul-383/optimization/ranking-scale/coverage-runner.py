import json, os, subprocess, time
from pathlib import Path
root=Path.cwd();out=root/'docs/validation/gul-383/optimization/ranking-scale'
env=dict(os.environ)
env.update(PATH=str(root/'.build/coverage-bin')+':'+env['PATH'],TYPEFLUX_RANKING_TEST_FILES=str(root/'.build/coverage-files.json'),TYPEFLUX_COVERAGE_SCRATCH=str(root/'.build/coverage-native'),TYPEFLUX_SEMANTIC_TEST_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_HOLDOUT_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'))
suites='SemanticSearchRankingTests SemanticScoreCalibrationTests SemanticSQLiteCancellationTests'
command=['make','coverage','SUITE='+suites]
start=time.monotonic()
with (root/'.build/coverage-candidate-guard-final.log').open('w') as log:
 result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
report=dict(command=command,wall_seconds=time.monotonic()-start,exit_code=result.returncode,source_files=json.loads((root/'.build/coverage-files.json').read_text()))
(out/'coverage-candidate-guard-final.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
if result.returncode: print((root/'.build/coverage-candidate-guard-final.log').read_text()[-10000:])
raise SystemExit(result.returncode)
