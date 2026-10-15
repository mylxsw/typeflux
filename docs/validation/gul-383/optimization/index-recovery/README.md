GUL-403 adds durable discovery/work queues and per-file pending/partial/done/skipped/failed jobs to the GUL-402 base `1e8cb5cf16ad7d474344094baf4f2f71a5a160b8`. Text and PDF extraction publishes FTS and the next UTF-8/page checkpoint atomically, then fills vectors in batches of eight. File identity/change time, generations and recipes reject obsolete results. Large documents rotate behind other work; media encoding checkpoints survive cancellation, decoder failure and restart. Confirmed scan ranges prune independently of unreadable subtrees or bad/empty files.

The final validation used one unchanged binary and a fresh profile directory: **96 methods in 16 suites passed**, including parameterized faults, in **115.36 seconds** including build/discovery, test startup/execution and coverage export. Swift Testing execution itself took 79.813 seconds. App changed executable lines: **1006/1031 (97.58%)**. The focused run's project-wide line report is 8,552/241,495 (3.54%); it is not full-project validation. C++ helper changes: zero, so there is no new helper coverage denominator. The Swift filesystem worker is included in app coverage. Exact uncovered executable lines are in `changed-coverage.json`; `coverage.lcov.gz` contains the final changed-source records, excluding unrelated application/tests/vendor files.

The three older optional live-download/model branches listed in `summary.json` returned before their opt-in bodies. The new `SemanticIndexEventTests` was explicitly enabled with the pinned model and Release helper and did execute. Its production service, FSEvents watcher, isolated file worker, SQLite FTS and real text embeddings covered add, rewrite, rename and delete. No network download was performed.

| Final native index measurement, 30 small-document arrivals | p50 ms | p95 ms | p99 ms |
| --- | ---: | ---: | ---: |
| Event to committed body FTS | 179.80 | 184.86 | 192.51 |
| Event to complete vectors | 562.09 | 580.07 | 638.66 |
| File write to body FTS | 191.59 | 197.43 | 204.34 |
| File write to complete vectors | 572.70 | 591.90 | 649.11 |

Hardware: Apple M4, 16 GiB, macOS 26.6.2. Configuration: Debug coverage app, reused Release C++ helper. Model SHA-256: `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135`; helper hash is in `binary-manifest.json`. One writer, zero interactive queries, one chunk per file, no backlog. Index/file workers are constructed anew for each reconciliation; OS page cache was not controlled. All arrivals, including the first, are in `events.json`; nearest-rank p99 is the maximum for n=30. These numbers measure index visibility, not keyboard-to-result rendering, FTS query latency or pure-semantic query completion. The event-to-body p95 meets this batch's <=1 s small-document target.

`summary.json` records sampled RSS for the worker/helper and a separate test-host window, with byte counts, sample counts and definitions. The host window begins after startup and is not a full-run high-water mark. Shared pages are double counted in sums; compiler memory is excluded. No memory reduction versus GUL-402 is claimed.

Deterministic completeness/recovery fixtures cover requested text sizes 90,000, 160,000 and 16,781,312 bytes (actual generated text also includes its tail marker), a 503-page PDF, and a single PDF page whose extracted text exceeds the read budget. Every tail is searchable and reaches done; reopening reuses completed reads/vectors. A real child `_exit(73)` preserves eight committed vectors. A child exits during a SQLite DDL transaction before migration and the database then migrates without losing the compatible payload. Native SQLite FULL, insert/update transaction faults, timeouts, malformed/nonadvancing replies, rewrite/delete, permission denial, scope revocation, rename/replay and selective prune are exercised. Media decoder failure reuses completed segments on retry. Old/unknown projector vectors are excluded during rebuild/pause, while compatible legacy document vectors remain searchable.

Large-file fixtures use deterministic unit vectors; their runtime is not real-model encoding throughput. The native text-model benchmark uses small files. Real media extraction runs through AVFoundation/file workers, while media vectors in these fault tests are fixtures. OCR/Office/media text coverage, query ranking, large-scale pure-semantic latency and final native UI regression remain the already planned GUL-404 through GUL-406 scope. PDFKit still materializes a page string internally; the held descriptor is opened lazily and output/IPC batches are bounded, but this is not a hard decoder RSS cap for a pathological single page. Media decoding can revisit its source after restart while reusing encoded segments.

The coverage scope maps persistence/faults to `SemanticIndexRecoveryTests`; chunking/content/storage to `SemanticFilePolicyTests`, `SemanticFileContentTests`, `SemanticFileStoreTests`; capacity/scheduling to `SemanticFileIndexerTests`, `SemanticFileCapacityTests`, `SemanticIndexPriorityTests`; media to `SemanticMediaIndexTests`, `SemanticMediaExtractorTests`; lifecycle/callers to `SemanticFileServiceTests`, `SemanticMediaServiceTests`, `SemanticRealtimeSearchTests`, `SemanticHybridSearchTests`; IPC to `AskFileReliabilityTests`, `AskFileStreamingTests`; and real events to `SemanticIndexEventTests`.

Reproduce with the task-local Swift 6.4 native coverage shim (its prebuild uses four jobs), local pinned model/helper files, and the explicit scope:

```sh
mkdir -p .build/coverage-bin
cp docs/validation/gul-383/optimization/index-recovery/coverage-swift.sh .build/coverage-bin/swift
chmod +x .build/coverage-bin/swift
export PATH="$PWD/.build/coverage-bin:$PATH"
export TYPEFLUX_COVERAGE_SCRATCH="$PWD/.build"
export TYPEFLUX_INDEX_EVENT_MODEL="$PWD/.build/semantic/embeddinggemma-2-Q8_0.gguf"
export TYPEFLUX_INDEX_EVENT_HELPER="$PWD/.build/semantic/TypefluxSemanticHelper"
export TYPEFLUX_INDEX_EVENT_REPORT="$PWD/docs/validation/gul-383/optimization/index-recovery/events.json"
make coverage SUITE="SemanticIndexRecoveryTests SemanticIndexEventTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticFileCapacityTests SemanticMediaIndexTests SemanticMediaExtractorTests SemanticFileServiceTests SemanticMediaServiceTests SemanticIndexPriorityTests SemanticRealtimeSearchTests SemanticHybridSearchTests AskFileReliabilityTests AskFileStreamingTests"
```

First app build: 231.03 s including dependency preparation. The first coverage build failed before tests on a nested test macro introduced by formatting (229.22 s), then passed after the fix. A later native build exited before tests with no fatal serialized diagnostic (57.87 s); the same scope passed using four build jobs. `summary.json` preserves every command's total wall time and exit code. An attempted cross-binary profile merge emitted counter mismatches; its 98.18% output was discarded. The reported 97.58% comes only from the final same-binary run. `validation-results.txt` contains test outcomes; full sanitized logs accompany the issue's validation archive. Lint comparison: 20 existing baseline findings versus 19 current, zero new findings or current errors. `git diff --check` passed.

Self-review checked entry-to-storage/search visibility, cancellation/generation changes, permissions, retries after failure, statement/descriptor/process/scratch cleanup, migration and documentation. It corrected pending jobs being counted as indexed, failure records being discarded during metadata/content invalidation, decoder errors dropping usable media checkpoints, and queries admitting incompatible media vectors. No settings defaults, filename/pinyin behavior, default Return action, search scope or voice priority changed.

Rollback: disable the experiment and use the built-in content-index clear action while keeping models, restore the prior app/revert this PR, then rebuild if desired. Delete/recreate the content database through that action; merely keeping the additive schema with the old positional INSERT writer is not a safe rollback. Source files and the filename index remain separate.
