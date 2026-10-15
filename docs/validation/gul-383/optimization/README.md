# GUL-402: realtime body search and recoverable semantic queries

Indexed body FTS now publishes independently of the model, vector scan and filename provider. Mixed launcher, `f` and the newly merged `ss` entry use progressive publication. Manual indexing pause, missing weights, a failed query and voice/thermal pressure preserve FTS. Query/model/index state are separate. The helper stays warm across obsolete input; voice/scope shutdown cancels its epoch. Background document batches yield to queries, and media segment checkpoints drain changed documents without repeating completed segments.

The experiment remains off by default. Device gating, shared scope, file permission checks, filename/pinyin search and safe default Return behavior remain covered. There is no schema/profile migration, new quota or dependency. Roll back the commit, or disable the content-search experiment; the existing database remains readable by the baseline.

## Measurement boundaries

- Apple M4, 16 GiB, macOS 26.6.2 (25G83), Swift 6.4. The repository pins Swift 6.3.1; this machine supplies 6.4.
- Pinned EmbeddingGemma Q8_0 model: 309,855,456 bytes, SHA256 `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135`. Native C++ revision is unchanged (`4d756bc72bf00a4aacf410ae15a2d315f3db400d`).
- 100,000 base Float32 chunks across **two text files**, using a real document embedding and synthetic noise vectors. Writer scenes add one replacement chunk/file. This is a repeatable scan/latency fixture, not a representative 100,000-document corpus. The filename provider is an empty ready fixture. Native file permission checks and the model helper are real.
- Each entry has 100 samples for cache, new noncached pure-semantic queries with asserted zero lexical matches, and concurrent writes; cold has one sample. Cold means a fresh query helper, with OS/model/shader caches potentially warm. Service/database preparation precedes panel input.
- Writer load is one replacement every 10 ms, **zero concurrent indexing inference**. Actual transcription/media throughput under shared GPU/memory pressure is not measured. Priority/voice behavior has separate functional tests. Cooperative background checkpoints bound a query's contention to the current document batch (at most eight texts) or media segment; this is not a hard wall-clock bound on an in-flight inference.
- Native timing starts immediately before `NSTextView.insertText`, includes committed native input, the production controller/service, main-actor publication, and forced layout/display plus accessibility verification. Drawing is **not a GPU presentation fence**. Timer gaps include test polling/accessibility overhead and are not a frame-rate measurement. This developer host is not reserved exclusively for benchmarking.

## Raw evidence

`native-publication-latency.json` contains the final native run. `native-publication-latency-initial.json` preserves the first run. `publication-latency.json` has 1,204 controller samples: a baseline algorithm replay and the new service through actual mixed/`f` sessions. Its replay includes the baseline's 160 ms delay, combined Store lookup and fresh permission reader; it uses the current worker adapter. **It is not a historical application binary benchmark.** That comparison predates the final `ss` compatibility and trace propagation changes; the native final run covers the delivered source.

`latency-summary.json` gives p50/p95/p99, sample/missing-hit counts, lock waits, helper encode/load, retrieval stages, RSS and thermal state. `summarize.py` regenerates it using nearest-rank percentiles. Neither Store-only nor helper-only measurements are presented as input-to-publication latency.

Final native results, milliseconds from committed input to main-actor publication:

| Scenario | N per entry | Mixed p50 / p95 / p99 | `f` p50 / p95 / p99 |
| --- | ---: | ---: | ---: |
| FTS, repeated query | 100 | 73.46 / 75.58 / 76.58 | 28.96 / 30.37 / 31.49 |
| New noncached pure semantic | 100 | 223.10 / 228.25 / 231.56 | 191.37 / 208.02 / 215.27 |
| FTS, concurrent writer | 100 | 72.78 / 74.19 / 74.81 | 29.46 / 30.18 / 33.75 |

The fixture meets the 100 ms FTS and 300 ms warm-semantic publication thresholds in this final run. This does **not** establish the representative production corpus gate. Cold semantic publication took 515.40 / 453.19 ms (one sample each, no distribution claim). FTS drawing p95 was 90.27 / 39.83 ms; semantic drawing p95 was 241.21 / 224.79 ms. App peak RSS was 609.55 MiB. Main-actor timer-gap p99 during new semantic queries was 61.27 / 12.69 ms, including polling/accessibility overhead; the mixed entry still warrants UI profiling. Final build plus measurements took 754.73 s (build 322.75 s, test 429.86 s).

The initial native run measured FTS publication p95 75.34 ms (mixed) / 30.84 ms (`f`), and new pure-semantic p95 321.75 / 287.23 ms. Its mixed semantic result misses the final 300 ms gate. In the controller comparison, hot vector scans have p95 148 / 180 ms versus model encode 16 / 17 ms; writer pressure raises vector scan p95 to 880 / 258 ms. FTS uses a separate WAL reader and avoids this scan. Remaining vector scan/writer/UI tail work belongs to GUL-404/GUL-406; this batch does not establish the final production corpus gate.

`helper-after.json` measures fresh-helper IPC at 696.62 ms and 100 unique warm queries at p50/p95/p99 13.05/14.51/16.80 ms, with child RSS about 492 MiB. `baseline-helper.json` retains the first-ever helper run (10.55 s cold, including initial Metal setup, sampled during app compilation). These cold definitions and host loads differ, so their difference is not an optimization speedup claim.

## Quality baseline

`queries.json` contains 200 traceable bilingual queries, eight groups of 25. `scripts/create_semantic_query_fixture.py` defines 25 hand-authored synthetic source facts and stable document/query IDs; every positive label has a source anchor. This is a single-author regression oracle, not independently judged relevance quality.

The real-model harness indexes only 50 text fixtures and evaluates all 200 queries. It keeps 75 missing/unmeasured long-tail, scan and timestamp fixtures in the denominator as failures. The media group is **unmeasured here**, not a claim that production lacks media embeddings. Lexical/identifier/short-Chinese recall@5 is 100%; cross-language recall is 44%, MRR 0.2013. All three absent groups have zero recall, and no-answer false-positive rate is 100%. Ranking/rejection and format coverage remain explicit failures for later batches. See `evaluation.json` and `evaluation-summary.json`.

## Validation and review

`validation-plan.json` maps behaviors to the focused suites and records build/retry wall times, including failures. The initial genuine coverage pass ran 110 Swift Testing methods plus one XCTest method successfully. A scoped boundary recheck then covered default/observed real-model document changes and targeted/full-rescan media preemption. Final validation passed **120 Swift Testing methods plus one XCTest method**: 37 compatibility methods (360.64 s), the remaining 83 methods (100.68 s), and one final permission-withdrawal regression (96.91 s). The first two use the identical binary (SHA checked); the final test adds only test code. It covers the newly merged keyword, progressive selection/cancellation, native IME, helper tracing/recovery, the real-model oracle and background/Store dependencies. The permission test simulates access loss and metadata EACCES after an early verified hit, and checks recovery for an ordinary temporary file; it does not revoke live macOS TCC or read protected personal files.

Swift 6.4 `swift test list` stripped instrumentation from previously instrumented objects. The task-local `coverage-swift.sh` forces `swift build --build-tests --enable-code-coverage`, verifies Mach-O `__llvm_covmap`, then discovers with `--skip-build`. Earlier uninstrumented attempts are retained as failures, not used for coverage. A trial merge across pre/post-main binaries also produced three LLVM counter mismatches; that aggregate was discarded. Only the three final profiles with unchanged application source are used: **673/694 changed executable app lines (96.97%)**, with no counter mismatch. New files are included. `changed_coverage.py` reproduces the git/LCOV intersection. No project-wide coverage claim is made.

`changed-app-coverage.json` and `changed-helper-coverage.json` report separate denominators and uncovered lines. Native helper raw coverage is 7/8 (87.5%): LLVM counts the moved, unchanged `entries = []` initializer thunk as uncovered in both optimized and debug wrappers. All seven changed behavioral statements are covered by real text-model/protocol validation. Vendor C++ and unchanged media inference are excluded, not claimed as covered.

Strict lint retains 106 pre-existing diagnostics in the touched production scope and introduces zero (`lint-comparison.json`). The comparison keys diagnostics by file, rule and source line; full strict lint is not green. Python benchmark/fixture tests pass (four methods). Native IME screenshots are in `ui/`.

Self-review checked the full input/publication/action chain, generation/cancellation and scope invalidation, permission withdrawal, query timeout/recovery, voice priority, helper ownership, SQLite lock ordering, media stream reentrancy, compatibility and documentation. Fixes from review include a separate priority metadata reader to avoid nested pipe reads, revalidating early FTS before final publication, rejecting stopped helper epochs, propagating trace context into the helper queue, and restricting panel warmup to the launcher.

## Reproduce

Use the pinned weights at `.build/semantic/embeddinggemma-2-Q8_0.gguf`; the tests do not download them or read personal documents. Build the optional helper with `scripts/build_semantic_helper.sh` (CMake required). On this host CMake 4.1.2 was installed in a task-local venv.

```bash
python3 scripts/create_semantic_query_fixture.py
python3 -m unittest discover -s scripts/tests -p test_semantic_helper_benchmark.py
python3 scripts/semantic_helper_benchmark.py \
  --helper .build/semantic/TypefluxSemanticHelper \
  --model .build/semantic/embeddinggemma-2-Q8_0.gguf \
  --report docs/validation/gul-383/optimization/helper-after.json

mkdir -p .build/coverage-bin
cp docs/validation/gul-383/optimization/coverage-swift.sh .build/coverage-bin/swift
chmod +x .build/coverage-bin/swift
export PATH="$PWD/.build/coverage-bin:$PATH"
export TYPEFLUX_COVERAGE_SCRATCH="$PWD/.build/coverage-native"
export TYPEFLUX_SEMANTIC_TEST_MODEL="$PWD/.build/semantic/embeddinggemma-2-Q8_0.gguf"
export TYPEFLUX_SEMANTIC_EVAL_MODEL="$TYPEFLUX_SEMANTIC_TEST_MODEL"
make coverage SUITE="SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticFileCapacityTests SemanticFileChangePlanTests SemanticFileServiceTests SemanticEmbeddingWorkerTests SemanticMediaWorkerTests SemanticMediaIndexTests SemanticMediaServiceTests SemanticHybridSearchTests SemanticContentSearchProgressTests SemanticFileSearchStatusTests SemanticRealtimeSearchTests SemanticLexicalSearchTests SemanticSearchEvaluationTests SemanticNativeInputTests SemanticLatencyTests SemanticIndexPriorityTests AskPluginSessionTests AskFileStreamingTests AskFileReliabilityTests AskComposerPlaceholderTests AskComposerTests AskSemanticFileSearchPluginTests" \
  FILTER="WorkflowControllerProcessingTests/testSemanticIndexingPriorityFollowsRecordingAndProcessing"
```

For Release measurements, run the compact test closure below **after coverage/build activity finishes**, using `/usr/bin/swift` to bypass the coverage shim. Run each suite sequentially; the exclusive UI trait also serializes them within one test process.

```bash
export TYPEFLUX_TEST_FILES='["ExclusiveUIStateTrait.swift","SemanticLatencyTests.swift","SemanticNativeLatencyTests.swift","AskConversationTests.swift","AskAppSearchTests.swift","AskFileSearchTestSupport.swift","SettingsBehaviorTestSupport.swift"]'
export TYPEFLUX_SEMANTIC_BENCH_MODEL="$TYPEFLUX_SEMANTIC_TEST_MODEL"
export TYPEFLUX_SEMANTIC_NATIVE_BENCH_MODEL="$TYPEFLUX_SEMANTIC_TEST_MODEL"
/usr/bin/swift test --build-system native --scratch-path .build/coverage-native \
  --configuration release --filter SemanticLatencyTests
/usr/bin/swift test --build-system native --scratch-path .build/coverage-native \
  --configuration release --filter SemanticNativeLatencyTests
python3 docs/validation/gul-383/optimization/summarize.py
```

Build/test logs, including failed attempts, are attached to the issue as a sanitized archive; local absolute paths are redacted. Runtime-local model binaries and full LLVM profiles are not committed.
