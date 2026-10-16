# Bounded semantic pending work and priority ownership

Base: main `9b3935af91e59078f2aa6ddf4bbc58c9f4065266`. Preserves watcher handoff, original lifecycle/download/health work, discovery checkpoints/subtree pruning, hidden progress rows and launcher icon optimization. This increment bounds downstream in-memory intents; it is not a global heap limit or synchronous filesystem permission transaction.

## Behavior and review

Service pending files/directories/fullScan now share the existing bounded plan union, including failure restoration. Across repeated watcher deliveries, each retained plan holds at most512 combined paths and128KiB UTF-8 path payload. Count/byte overflow retains full-scope reconciliation instead of an unbounded set. Event high-water marks remain independent; no receipt is acknowledged by merging an intent. Reconciliation and catch-up keep existing checkpoint, failed-directory, partial queue and prune semantics.

The priority document gate uses the same bound. Overflow retains a priority discovery marker and explicitly returns a full-reconciliation requirement to the owning service. The service retains that full-scope obligation because priority document discovery alone cannot prune deleted files. This matters when a gate overflows independently of the service's current pending set. No new retry/pause/restart/throttle mechanism was added: priority discovery uses the existing segment/document-boundary drain, and full reconciliation uses the existing dirty/fullScan path after active work/conditions permit. Overflow latency/performance is not proven.

Priority intents are now bound to an immutable original cancellation source. Startup binds the new source atomically, and each actual indexer captures it before scheduling. Enqueue/take check identity and cancellation under the state lock. Old workers and standalone callers cannot drain a replacement service's queue. Clear/deinit invalidate queued intents. Binding/invalidation does not clear actual query occupancy; the original query must end before its pressure is released. Existing pause/foreground conditions and independent native/reader/model health budgets remain unchanged.

Standalone/custom indexers retain their own local source and original small targeted/explicit scan behavior. Overflow is exposed by enqueue's return and DocumentWork.overflowed; custom owners must retain full reconciliation when needed, rather than treating a document-only scan as deletion/prune completion. All production enqueue/take sites in SemanticFileSearchService use the explicit original source and propagate overflow. No global test bypass, helper/pool/fullDI or new permission/model grant was added.

Self-review before testing included source replacement between poll and new enqueue, lock boundaries, query occupancy, pending failure restoration, document-only discovery versus deletion pruning, checkpoint timing and fresh-event triggers after failure. Already-entered writes are not rolled back. Failure restoration keeps obligations but does not schedule an automatic retry; existing explicit/new-event reconciliation remains responsible. No generic DB/model install retry, recovery deletion, health-triggered preparation/download/query/scan or side-effect replay was added. Stronger authority ordering for other already-entered off-actor worker/SQLite operations remains subsequent work.

## Focused validation

Direct commands used scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit methods in semantic-pending-work-methods.json>'
```

Prebuilt inventory used native_tools/native_environment/swiftpm-testing-helper, not XCTest as a program. Both app/test binaries contain __llvm_covmap and __llvm_prf_cnts. Methods JSON records exact names/backticks. SemanticMediaIndexTests was restricted to the synthetic document-events-preempt method (four parameterized cases); its real-file method was not run.

**91/91 distinct Swift Testing methods in22 suites passed on the first functional run**,27.035s execution. No XCTest methods ran. Six new methods cover100,000 enqueue operations, byte overflow, standalone scan compatibility, old source/standalone unable to steal replacement intents, binding/invalidation retaining actual query occupancy, paused multi-batch file/directory overflow, active priority overflow followed by deletion catch-up, and bounded failure restoration with a fresh-event trigger. Actual private DB tests hold priority/discovery work and verify checkpoint ordering; previously committed deleted-file records are removed by full catch-up rather than incorrectly acknowledged by document discovery. Existing scope/download/health admission, count/progress ownership, partial index, priority/media boundaries, pause, checkpoints/subtree pruning and filename/lexical/query permission compatibility passed.

Build274.99s passed, no changed-file warnings; existing unrelated warnings/native-build deprecation remain. Inventory4.439s; focused command51.45s; archive3.655s. Core tracked build/inventory/test total330.879s excludes archive/extraction/audits/platform work. No retries, production timeout relaxation or Source/test input changes after the build.

## Coverage evidence

Changed executable lines vs stated main base: **52/52 (100%)**, service20/20 and gate32/32. This measures changed executable lines, not every branch/interleaving, native allocation, errno or device.

Only two fresh final HOST profiles from one binary (XCTest discovery and Swift Testing host). Each raw validated; merge warning-free; prior codecov moved before test stamp and root default profiles excluded. llvm-cov uses the matching app --object with empty show/export stderr. No old/cross-layout merge or child-process coverage claim. Swift function hashes are zero and cannot establish layout compatibility; fresh matching objects and source hashes establish evidence scope.

Before/after hashes matched1,126 production Swift files,807 test Swift files and both binaries. Private evidence .build/semantic-pending-work-validation/final:

- Test host SHA-256: `563ec40b4797bace20a9f92bb4d1b1858ad03f8384f8df1f6fe88e0d8dba3e7f`
- App SHA-256: `57f387246327c37701dc65b8f6281e4c29bd9de232c6f9dffcd30c45d2754bd4`

## Limits and remaining work

Bounds apply to retained aggregate intents, not caller/native input arrays, per-path normalization temporaries, immutable configuration, persisted work queues/failed-directory query results, or every active snapshot/producer. A taken bounded DocumentWork and a new pending plan may coexist. Arbitrary host/native crash/OOM/power-loss immunity is not provided; HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries. Other original-producer/permission ordering, broader feature/native/media lifecycle and device/signing/performance work remain.

Private synthetic documents/models/readers/encoders/transfers/watchers/history/schedulers only, with existing harmless shell-protocol and injected URLProtocol fixtures. New service receipt tests use deterministic history; existing fixtures read only current FSEvents ID/private-root volume metadata with fake watchers. No real weights/CoreML/provider/network/model downloads/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. Real model/media/event/permission methods and independent icon tests excluded. The icon baseline is compiled here, without claiming independent icon behavior validation. No presentation/helper ABI/entry/package change in this increment, so no new screenshot/copied probe. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified; microphone ownership still follows audio/TCC/signing/performance prerequisites.
