#!/usr/bin/env python3
"""One focused product coverage pass after implementation and self-review."""
import json,os,subprocess,time
from pathlib import Path
root=Path.cwd();out=root/'docs/validation/gul-383/optimization/ranking-scale'
env=dict(os.environ)
env.update(PATH=str(root/'.build/coverage-bin')+':'+env['PATH'],TYPEFLUX_RANKING_TEST_FILES=str(root/'.build/rework-test-files.json'),TYPEFLUX_COVERAGE_SCRATCH=str(root/'.build/gul404-rework-coverage'),TYPEFLUX_SEMANTIC_TEST_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_HOLDOUT_MODEL=str(root/'.build/semantic/embeddinggemma-2-Q8_0.gguf'),TYPEFLUX_SEMANTIC_RANKING_COMPARISON='1',TYPEFLUX_SEMANTIC_LABEL='coverage-rework',TYPEFLUX_SEMANTIC_SCREENSHOTS=str(root/'.build/rework-screenshots'))
suites='SemanticDurableEventsTests SemanticSearchMigrationTests SemanticWorkBudgetTests SemanticPagedDiscoveryTests SemanticIndexDiagnosticsTests SemanticIndexProgressRelayTests SemanticBoundedSnapshotTests SemanticFileChangePlanTests SemanticFileServiceTests SemanticPreparationServiceTests SemanticRealtimeSearchTests SemanticHybridSearchTests SemanticLexicalSearchTests SemanticSQLiteCancellationTests SemanticSearchRankingTests SemanticScoreCalibrationTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticIndexRecoveryTests SemanticIndexFairnessTests SemanticIndexFairnessServiceTests SemanticIndexPruneTests SemanticIndexPriorityTests SemanticMediaIndexTests SemanticMediaServiceTests SemanticMediaExtractorTests SemanticMediaWorkerTests SemanticEmbeddingWorkerTests SemanticFileSearchStatusTests SemanticFileSearchVisualTests SemanticContentSearchProgressTests SemanticNativeInputTests SemanticRankingComparisonTests AskFileStreamingTests AskFileReliabilityTests'
command=['make','coverage','SUITE='+suites]
start=time.monotonic()
with (root/'.build/gul404-rework-coverage.log').open('w') as log:result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
report=dict(command=command,wall_seconds=time.monotonic()-start,exit_code=result.returncode,source_files=json.loads((root/'.build/rework-test-files.json').read_text()),scope='New durable events, paged discovery, resumable migration, diagnostics, compute budget and bounded snapshots; affected writer, lexical/vector readers, permission/cancellation, service, both launcher entrypoints and native settings rendering. Frozen-vector ranking replay is controlled quality evidence, not an input/render benchmark.')
(out/'rework-coverage-run.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
raise SystemExit(result.returncode)
