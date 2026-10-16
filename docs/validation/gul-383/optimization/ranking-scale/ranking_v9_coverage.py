#!/usr/bin/env python3
"""One focused product coverage pass after implementation and self-review."""
import json,os,subprocess,time
from pathlib import Path
root=Path.cwd();out=root/'docs/validation/gul-383/optimization/ranking-scale'
env=dict(os.environ)
env.update(PATH=str(root/'.build/coverage-bin')+':'+env['PATH'],TYPEFLUX_RANKING_TEST_FILES=str(root/'.build/rework-test-files.json'),TYPEFLUX_COVERAGE_SCRATCH=str(root/'.build/gul404-rework-coverage'),TYPEFLUX_SEMANTIC_TEST_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_HOLDOUT_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_RANKING_COMPARISON='1',TYPEFLUX_SEMANTIC_LABEL='coverage-development-v9',TYPEFLUX_RANKING_FIXTURES='development-v9',TYPEFLUX_SEMANTIC_SCREENSHOTS=str(root/'.build/rework-screenshots'))
suites='SemanticSearchRankingTests SemanticScoreCalibrationTests SemanticCalibratedEvaluationTests SemanticSearchEvaluationTests SemanticHybridSearchTests SemanticLexicalSearchTests SemanticRankingComparisonTests SemanticRealtimeSearchTests SemanticNativeInputTests SemanticFileServiceTests SemanticMediaServiceTests'
command=['make','coverage','SUITE='+suites]
start=time.monotonic()
with (root/'.build/gul404-ranking-v9-coverage.log').open('w') as log:result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
report=dict(command=command,wall_seconds=time.monotonic()-start,exit_code=result.returncode,source_files=json.loads((root/'.build/rework-test-files.json').read_text()),scope='Development-v9 selected zero distribution calibration and explicit format requests. Preserve existing weak-confidence gates (tie favored minimal policy change). Self-review: exact identifiers/quotes and raw answerability stay intact, cancellation and scope checks remain in both vector passes; query-local distribution maxima no longer allocated. Focused coverage of changed ranking/vector reader, lexical/hybrid/shared callers and both native entrypoints. Actual Swift development replay uses the same546 original query labels with127 sources; all prior heldouts retained, not used for selection.')
(out/'ranking-v9-coverage-run.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
raise SystemExit(result.returncode)
