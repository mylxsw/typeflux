#!/usr/bin/env python3
"""One focused product coverage pass after implementation and self-review."""
import json,os,subprocess,time
from pathlib import Path
root=Path.cwd();out=root/'docs/validation/gul-383/optimization/ranking-scale'
env=dict(os.environ)
env.update(PATH=str(root/'.build/coverage-bin')+':'+env['PATH'],TYPEFLUX_RANKING_TEST_FILES=str(root/'.build/rework-test-files.json'),TYPEFLUX_COVERAGE_SCRATCH=str(root/'.build/gul404-ui-rework-coverage'),TYPEFLUX_SEMANTIC_TEST_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_HOLDOUT_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_RANKING_COMPARISON='1',TYPEFLUX_SEMANTIC_LABEL='coverage-development-v9',TYPEFLUX_RANKING_FIXTURES='development-v9',TYPEFLUX_SEMANTIC_SCREENSHOTS=str(root/'.build/rework-screenshots'))
suites='AskLauncherHomePermissionTests AskLauncherHomeTests AskScreenshotPluginTests AskScreenshotFollowUpTests SemanticNativeInputTests SemanticRealtimeSearchTests'
command=['make','coverage','SUITE='+suites]
start=time.monotonic()
with (root/'.build/gul404-home-ui-coverage.log').open('w') as log:result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
report=dict(command=command,wall_seconds=time.monotonic()-start,exit_code=result.returncode,source_files=json.loads((root/'.build/rework-test-files.json').read_text()),scope='A failed100k mixedFTS stratum measuredp95128.42ms before intrusive profiling. Its main-thread sample repeatedly entered synchronous TCC preflight through launcherHomeContext/chipTitle/reportHeight. Coalesce one consistent read per capture plugin per home snapshot; preserve checks on the next snapshot and actual capture plan. Self-review: display struct copies never replace execution-registry plugins, no persistent permission cache or permission grant, disabled/missing/noncapture plugins retain semantics. Focused coverage: new count/freshness/actual-plan regression, existing home rendering/context and screenshot/OCR label/action callers, plus both native semantic inputs and shared realtime publication. Earlier core source files remain byte-identical and retain separate profiles.')
(out/'home-ui-coverage-run.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
raise SystemExit(result.returncode)
