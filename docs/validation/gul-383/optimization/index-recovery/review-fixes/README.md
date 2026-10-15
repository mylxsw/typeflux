PR #520 review follow-up to head `8c18ab215cb9cedb99bed1fc82e1c1fe177a92c6` fixes both reported findings. Full discovery and event replay now use the same durable queue. Every document batch consumes live events before selecting another path, including document work that preempts a media stream. Partial files rotate; event handling no longer recursively drains a whole long file. Progress drops the initial total when live document arrivals invalidate it.

Pruning selects stale paths from committed files, jobs, private media jobs and queued work, then deletes all their state in the same bounded transaction. Foreign keys/triggers remove chunks, FTS and private media segments. Failed/pending unconfirmed directory subtrees retain jobs, reasons, generations, segments and queued work. Those queued paths are withheld until discovered or explicitly replayed. Excluded roots count as confirmed scope removal rather than scan failure.

Validation passed **103/103 methods in 19 suites**, with parameterized cases, using one final binary and a fresh profile directory. `make coverage` took **213.40 s** including preparation, discovery, execution and report export; runner preparation/discovery was 91.79 s and execution 117.06 s. The focused project's line report is 8,551/241,513 (3.54%); this is not full-project validation.

| Coverage denominator | Covered / executable changed lines | Percent |
| --- | ---: | ---: |
| Follow-up versus reviewed head `8c18ab21` | 108 / 109 | 99.08% |
| Whole PR versus base `1e8cb5cf` | 1035 / 1070 | 96.73% |
| Native C++ helper | 0 changed lines | no new denominator |

Both denominators intersect added/modified app Swift lines with LLVM LCOV DA records; tests/vendor code are excluded. Exact line lists are in `fix-coverage.json` and `pr-coverage.json`. The follow-up's one unhit record is the closing brace at `SemanticFileIndexer+Priority.swift:77`. Whole-PR unhit records also include the now-unused candidate iterator and uncommon corruption/cancellation branches. `coverage.lcov.gz` contains the current PR's changed-source records; no counters were merged across binaries. Source, file-worker, test-binary, model and helper hashes are recorded separately.

The new `SemanticIndexFairnessTests` covers full/targeted processing, repeated live events, long-file arrivals during media preemption, and cancellation/reopen without new events. `SemanticIndexFairnessServiceTests` first reaches ready, rewrites a long document, injects another file event during its first encoding batch, and verifies the new small document's FTS, vectors and service search results while the long document remains partial. It uses the production service, isolated `AskFileReader` and SQLite store; watcher delivery and embeddings are deterministic. It is a scheduling regression, not a model-speed measurement.

`SemanticIndexPruneTests` checks 130 stale checkpoints across multiple batches, a transaction-abort trigger, cancellation, offline deletion, subtree/root exclusion, removal of the root, and EACCES followed by recovery. The failed subtree retains its complete media checkpoint and failure reason across reopen, while a similarly prefixed sibling is pruned. The recovered file uses real AVFoundation/file-worker extraction and reuses its stored segment without encoding it again. Assertions cover files, chunks, lexical terms, jobs, media jobs/segments and the work queue.

The remaining scope covers affected callers and dependencies: recovery/faults (`SemanticIndexRecoveryTests`); policy/storage/content (`SemanticFilePolicyTests`, `SemanticFileStoreTests`, `SemanticFileContentTests`); incremental/capacity/query priority (`SemanticFileIndexerTests`, `SemanticFileCapacityTests`, `SemanticIndexPriorityTests`); media extraction/indexing/service (`SemanticMediaExtractorTests`, `SemanticMediaIndexTests`, `SemanticMediaServiceTests`); lifecycle/query callers (`SemanticFileServiceTests`, `SemanticRealtimeSearchTests`, `SemanticHybridSearchTests`); reader IPC (`AskFileReliabilityTests`, `AskFileStreamingTests`); and real events (`SemanticIndexEventTests`). Three older opt-in live download/checksum/media branches were not enabled. The pinned-model event test was enabled and executed.

| Real FSEvents visibility, all 30 arrivals | p50 ms | p95 ms | p99 ms |
| --- | ---: | ---: | ---: |
| Event to body FTS | 179.02 | 184.74 | 187.07 |
| Event to complete vectors | 554.80 | 644.03 | 3347.88 |
| File write to body FTS | 190.00 | 195.51 | 199.39 |
| File write to complete vectors | 565.59 | 656.34 | 3358.01 |

The first arrival's vectors took **3347.88 ms** from the event and its FTS took 178.19 ms. It remains in all-sample percentiles. Following 29 arrivals: vector p50/p95/p99 554.80/605.51/644.03 ms. OS page cache was not controlled, so these are first/following arrivals rather than a controlled cold/hot comparison. Each reconciliation creates fresh file/embedding workers. The body p95 meets this batch's <=1 s small-document criterion; vector startup remains visible and is not described as instantaneous.

Hardware/configuration: Apple M4, 16 GiB, macOS 26.6.2, Debug coverage app/file worker plus reused Release C++ helper; one writer, one chunk per synthetic file, serial arrivals without backlog, zero interactive queries during event measurements. Model SHA-256 `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135`. `events.json` contains every raw sample; `environment.json` and `binary-manifest.json` fix the environment/artifacts. No native UI or large-file real-model throughput claim is made.

491 process-tree RSS samples at 200 ms intervals captured per-process peaks of 561,676,288 bytes for the test host, 81,838,080 for a file worker and 515,031,040 for the native embedding helper. These are sampled peaks over the focused test window, excluding compilers; short peaks can be missed, and shared pages are counted in each process. They are not a full-app high-water mark or a before/after memory comparison. Raw samples are in `rss.json`.

Build history: the copied cache failed on an absolute module-cache path in **55.66 s**; removing only relocated architecture products and retaining dependency/model downloads gave a successful full app compilation in **133.94 s** (`swift build --build-system native --jobs 4 --enable-code-coverage`). The first coverage preparation failed before any tests in **170.96 s**: new test callbacks had unhandled throwing assertions, visible in serialized diagnostics. The callbacks now record database errors as test issues. The same 19-suite command then passed. Every attempt's command and wall time is retained; no failed attempt is counted as validation. Changed-source SwiftLint reports zero findings, and `git diff --check` passes.

Reproduce using the parent directory's coverage shim and model/helper setup, pointing `TYPEFLUX_INDEX_EVENT_REPORT` at this directory's `events.json`, then:

```sh
make coverage SUITE="SemanticIndexFairnessTests SemanticIndexFairnessServiceTests SemanticIndexPruneTests SemanticIndexRecoveryTests SemanticIndexEventTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticFileCapacityTests SemanticMediaIndexTests SemanticMediaExtractorTests SemanticFileServiceTests SemanticMediaServiceTests SemanticIndexPriorityTests SemanticRealtimeSearchTests SemanticHybridSearchTests AskFileReliabilityTests AskFileStreamingTests"
```

Self-review checked the full discovery/event/FTS/vector path, generation checks, cancellation, repeated events, privacy/scope changes, failure recovery, transaction boundaries, statements, processes, scratch cleanup and progress/documentation. It also found and fixed queued work overwriting an unconfirmed failed subtree's checkpoint and an excluded root incorrectly retaining failed-scan protection. No schema migration or native helper changes were needed for this follow-up. The parent report's PDFKit page-allocation/media re-decoding limits and rollback procedure still apply. Arch independently reviews and merges this PR; GUL-404 onward remains parked until that review succeeds.
