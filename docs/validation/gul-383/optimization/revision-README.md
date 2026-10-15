# GUL-402 revision after independent review

`prepare()` now distinguishes a cached vector from a running helper. It checks process state on the worker queue and reloads after idle release, while ordinary query vectors remain cached. Coalesced preparation requests also require a running helper. The idle period remains 60 seconds; the regression exercises the actual dispatch timer with a 100 ms injected interval, then checks a fresh query reuses the reloaded process. Cancellation and voice-stop epoch invalidation are covered separately.

The only product changes in this revision are in `AskFileReader.swift` and `SemanticEmbeddingWorker.swift`. No schema, settings default, model, inference kernel or media policy changed.

## Validation

The focused scope maps the worker change to `SemanticEmbeddingWorkerTests`, service lifecycle/recovery to `SemanticFileServiceTests` and `SemanticRealtimeSearchTests`, both callers to `SemanticHybridSearchTests` and `SemanticNativeInputTests`, reader compatibility to `AskFileReliabilityTests` and `AskFileStreamingTests`, and background coordination to `SemanticIndexPriorityTests`, `SemanticMediaIndexTests` and `SemanticMediaServiceTests`.

All **64 tests in 10 suites passed**. The real text-model IPC method was enabled, rather than taking its environment guard. The idle release regression checks first warmup, retained query cache after release, second warmup, fresh-query reuse, cancelled warmup, and voice-stop restart.

- Initial `make coverage` preparation failed after 332.83 s without surfacing a compiler diagnostic; no test results came from that attempt. A direct diagnostic build succeeded in 52.64 s. The same focused coverage command then passed in 120.72 s including report generation (runner: 115.14 s; discovery/build: 37.74 s; tests: 68.804 s). All attempt logs are retained. No passing result was reused.
- Mach-O coverage sections were verified before execution. Current LLVM LCOV gives **15/15 (100%)** executable product lines changed since review head `69aa4446`, and **676/703 (96.16%)** for the entire application PR against base `fa9643cf`. See `revision-changed-coverage.json`, `revision-pr-coverage.json` and the attached raw LCOV. No project-wide coverage claim is made.
- Native helper source did not change in this revision. Its historical raw 7/8 coverage remains separate; this run does not claim fresh helper-wrapper coverage.
- Strict lint on the two changed product files reports the same three baseline diagnostics and zero additions (`revision-lint.json`). Full strict lint is not green. `git diff --check` passes.

## Measurement protocol

`revision-environment.json` records the M4 / 16 GiB host, OS/compiler and exact model/projector/helper hashes. The Release helper is reused from the initial build of unchanged helper source. Native timing uses the actual composer, `NSTextView.insertText`, production mixed/`f` controllers, production search service, permission helper, and production background indexer.

Each entry begins with 100,000 chunks: one real document embedding plus synthetic noise across two files. The service then indexes 128 real temporary geology documents with the real text model. Unlike the initial writer test, no precomputed vector is used for background work. Every timed input must fall inside a recorded real background embedding batch; raw intervals show the overlap and completion. Each entry has 100 FTS queries and 100 unique noncached queries with asserted zero lexical matches. Counts at the end show actual background additions. This remains a controlled latency fixture, not a representative 100,000-document relevance corpus.

Timing separates input-to-publication, forced layout/display plus rendered accessibility verification, and complete search. Layout/display is not a GPU presentation fence. Main-actor timer gaps include polling and accessibility work. Background scheduling is cooperative: a current batch can finish; subsequent batches yield to a query. It is not a hard wall-clock preemption guarantee.

The media integration uses a real 65-second generated speech WAV, real filesystem extraction, pinned media projector, SQLite and FSEvents. An explicit barrier holds only the first completed media callback while the test creates a document and applies foreground voice priority. Real SenseVoice CPU transcription runs while media is paused and body FTS remains available. After voice ends, the document must publish while media still waits for idle; media then resumes at 30 and 60 seconds, with no repeat of the completed 0-second segment. Foreground activity is driven at the service boundary; existing workflow callback regression supplies the wiring evidence. This is a functional integration check, not a media or transcription performance benchmark. `revision-fixtures.json` records synthetic audio hashes, generation text and ASR assets; no microphone or personal documents are used.

## Native contention results

400 native samples passed, with 100 per entry/scenario and a real background inference interval overlapping every input. Native edit/close cancellation checks passed for both entries. The Release command took **837.27 s**, including **400.97 s** of build time and **429.821 s** for the two selected tests (the exclusive UI trait serializes their shared state).

Milliseconds from committed input to first validated main-actor body result; nearest-rank percentiles:

| Entry / scene | N | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| file-mode/fts-real-index | 100 | 31.17 | 33.45 | 52.21 |
| file-mode/semantic-real-index | 100 | 231.89 | 321.33 | 342.54 |
| mixed/fts-real-index | 100 | 75.24 | 77.76 | 81.10 |
| mixed/semantic-real-index | 100 | 257.05 | 264.61 | 266.60 |

FTS meets 100 ms in both controlled contention scenes. **The `f` pure-semantic p95 of 321.33 ms misses the final 300 ms gate.** Mixed is 264.61 ms. This batch therefore does not establish the final semantic latency gate. GUL-404 must address the remaining exact vector scan/permission and shared inference tails, then rerun a representative corpus; GUL-406 must retain cold and UI validation. No issue was advanced or merged by this development run.

The current background batch cannot be preempted between its at-most-eight texts. Remaining active-batch time at input has p95 259.22 / 293.53 ms and p99 262.29 / 299.36 ms for new semantic queries (mixed / `f`). These observations and the unchanged linear 100k vector scan identify the remaining work boundaries; this run does not isolate how much of the semantic tail comes from GPU contention versus vector retrieval or permission validation. Earlier isolated stage timings remain historical evidence, not a new causal breakdown.

Semantic draw-check p95 is 289.63 / 349.41 ms. Distributions of each query's maximum main-actor polling gap have p95 61.21 / 27.79 ms and p99 62.03 / 37.42 ms. They include accessibility/forced-layout work and do not measure frame intervals. App `getrusage` peak is 669.19 MiB. Sampled helper RSS peaks at 1596.56 MiB; ASR at 761.28 MiB. The largest simultaneous named-child RSS sample is 1930.28 MiB; it excludes the runner, whose high-water mark is reported separately, and double counts shared pages.

Indexing completed 768 / 206 real batches; the corpus grew to 106,016 / 101,598 chunks. Thermal state was 0 before and 0 after (0 = nominal). The host was not reserved exclusively for benchmarking. Raw rows, inference intervals, RSS samples, and p50/p95/p99 for all metrics are in `native-inference-contention.json`, `revision-release-resources.json` and `revision-summary.json`. `summarize_revision.py` verifies sample counts, Release builds and actual inference/media ordering before summarizing.

## Media and voice observations

`real-media-priority.json` records segment times **0, 30, 60**. The 30-second segment started after the new document's result returned to the main-actor caller and after the real transcription ended. This media check ends at the service caller; native rendering is measured separately. Completed segments were not re-encoded. Actual FSEvents reported the new file; the test did not inject a watcher event or a vector.

The single ASR call used 5.569 s of generated speech and returned nonempty text in 1.234 s including startup. Body FTS remained usable during it, taking **219.01 ms** on this service's first search with a cold permission helper. This does not meet a 100 ms cold-call target and is not counted as a warm native publication sample. Change-to-result was 5.275 s including FSEvents, voice priority and the subsequent document/query work; voice completion to full search result was 3.412 s. These are single functional observations, not percentiles or throughput claims. The first real media embedding call took 54.252 s including lazy runtime preparation; later calls took 0.637 / 0.519 s. Its cold phases were not isolated, so no single-component attribution is made. Cold permission/model/media preparation remains a limitation for later performance/final-validation work.

## Reproduce

Run coverage before Release measurements. Use the coverage shim and `make coverage` setup from the main README with this focused scope:

```bash
make coverage SUITE="SemanticEmbeddingWorkerTests SemanticRealtimeSearchTests SemanticFileServiceTests SemanticIndexPriorityTests SemanticNativeInputTests AskFileReliabilityTests AskFileStreamingTests SemanticMediaIndexTests SemanticMediaServiceTests SemanticHybridSearchTests"
```

Prepare the pinned text model and projector under `.build/semantic`; neither test silently downloads assets. Generate synthetic audio with `say -v Samantha` using the text in `revision-fixtures.json`, convert with `afconvert -f WAVE -d LEI16@16000 -c 1`, then repeat PCM to exactly 65 seconds. Provide an isolated folder containing the already installed SenseVoice model directory and compatible sherpa runtime directory (symlinks are sufficient).

```bash
export TYPEFLUX_TEST_FILES='["ExclusiveUIStateTrait.swift","SemanticLatencyTests.swift","SemanticNativeContentionTests.swift","SemanticRealMediaPriorityTests.swift","SemanticFileSearchTests.swift","AskConversationTests.swift","AskAppSearchTests.swift","AskFileSearchTestSupport.swift","SettingsBehaviorTestSupport.swift"]'
export TYPEFLUX_SEMANTIC_CONTENTION_MODEL="$PWD/.build/semantic/embeddinggemma-2-Q8_0.gguf"
export TYPEFLUX_SEMANTIC_CONTENTION_PROJECTOR="$PWD/.build/semantic/mmproj-embeddinggemma-2-Q8_0.gguf"
export TYPEFLUX_SEMANTIC_CONTENTION_AUDIO="$PWD/.build/semantic/priority-media.wav"
export TYPEFLUX_SEMANTIC_CONTENTION_SPEECH="$PWD/.build/semantic/priority-speech.wav"
export TYPEFLUX_SEMANTIC_CONTENTION_ASR="$PWD/.build/asr-assets"
python3 docs/validation/gul-383/optimization/run_with_rss.py \
  --log .build/revision-release.log \
  --report docs/validation/gul-383/optimization/revision-release-resources.json -- \
  /usr/bin/swift test --build-system native --scratch-path .build/coverage-native \
  --configuration release --filter 'SemanticNativeContentionTests|SemanticRealMediaPriorityTests'
```

The opt-in methods return without measuring when their asset environment is absent. A passing guard alone is not real-model evidence; require the JSON artifacts and nonempty rows/segments. The resource wrapper joins its foreground command and samples descendant RSS at 500 ms intervals. RSS sums double count shared pages; they are not unique physical memory.

## Self-review and remaining scope

Self-review checked the complete preparation/query/release path, coalesced requests, cancellation and shutdown epochs, process/pipe ownership, serial access to reader state, scope/permission guards, temporary audio/model cleanup, and evidence/source consistency. The defect fixed here was treating the warmup vector as proof that a released helper was still ready. Fixture review also corrected close handling to use visibility cancellation and plugin deactivation before checking stale publication.

The 200-query quality failures, representative corpus validation, cold media/model costs, exact scan scaling and UI timing tails remain in the optimization chain. No recall-quality completion is claimed. Reverting the two product-file changes restores the reviewed initial worker behavior; the full PR can be reverted without a database migration. Disabling the experiment remains the operational rollback.
