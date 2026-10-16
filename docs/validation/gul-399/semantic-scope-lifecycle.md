# Semantic original-scope lifecycle fences

Base: main `c94ebc9e4734b9b55be62a8ca468bc167dc9dd4a`. Preserves the integrated health/download progress work, d883 discovery checkpoints/targeted subtree reconciliation, and c94 hidden progress rows. This is a lifecycle-admission prerequisite; bounded lossless watcher-event delivery remains subsequent work.

## Change and self-review

MainActor boundaries now check original token identity, cancellation, captured/current settings fingerprint and removal state. Startup checks ownership before detached preparation and after preparation/counts/model verification, including its failure path. A queued watcher callback carries the original token/fingerprint into receiveChanges; stale events cannot mutate pending paths/directories or event IDs. The delayed reconcile task retains that same ownership instead of adopting mutable current state after its delay. Scheduling and actual reconcile admission both check it.

Index attempts check the same ownership plus original attempt identity before their MainActor event-checkpoint write, terminal state and after count awaits. The detached discovery-checkpoint callback additionally checks its original cancellation token immediately before entering the existing write. Pause/foreground/thermal pressure may always stop old work; only a current original scope may resume it or publish a phase transition. No new model/source/FDA/account grant is created, and internal starts retain existing old grants.

Self-review covered all edited suspension/callback boundaries, clear/replacement cancellation, stale success/error, pending event-ID ordering, startup and final count waits, and foreground priority. Review caught the pause ordering issue before functional tests: a stale scope must still accept stop pressure while refusing resume. No existing scan checkpoint/subtree/prune logic, partial committed index, priority/pause semantics, query fallback or helper ABI was replaced. Already-entered effects cannot be rolled back.

The worker's off-actor file/FS/DB operations still use existing token/reader admissions; these MainActor fingerprint checks are not a synchronous permission transaction over all producer work. The detached discovery checkpoint cannot read actor-owned settings directly. Stronger producer authority ordering and bounded watcher-event handoff remain explicit next work; no claim that every settings change synchronously revokes an already-entered operation. Watcher callbacks still schedule one Task per event batch, so events were not incorrectly treated as replaceable progress. No event dropping, write retry, model/DB deletion, recovery scan, or side-effect replay was added. Health remains availability only.

## Focused validation

Implemented/self-reviewed before mapped functional tests. Direct native build/test commands used `scripts/test_runtime.child_environment`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit methods in semantic-scope-lifecycle-methods.json>'
```

Prebuilt discovery used native_tools/native_environment/swiftpm-testing-helper, not XCTest as a program. Exact method identifiers including literal backticks are in the methods JSON. Both app and test binary contain __llvm_covmap and __llvm_prf_cnts.

**76/76 distinct Swift Testing methods in 18 suites passed on the first functional run**, 29.198s execution; parameterized invocations remain method counts. No XCTest test methods ran. Five new methods/seven parameterized cases cover settings changed while initial counts or model verification are held, late success/error, queued watcher after settings edit, delayed reconcile with/without pause/resume, and entered index completion unable to advance an old event checkpoint or terminal state. Existing download original consent/admission, uncooperative install, count/progress ownership, restart skip/manual rescan, targeted subtree pruning, partial index, priority/pause and filename/lexical/query permission compatibility passed.

Initial build failed in330.23s on one new fixture macro expression missing inner `try`. Corrected the fixture and the reviewed pause ordering before any functional test. Final build passed in66.67s, with no changed-file warnings; unrelated existing warnings/native-build deprecation remain. No Source/test inputs changed after final build. Inventory6.598s; focused command65.36s; archive13.653s. Core tracked build/inventory/test total468.858s excludes archive/extraction/audits/platform delivery. No functional retry or production timeout relaxation.

## Coverage and evidence

Changed executable lines vs c94 base: **30/31 (96.77%)**. The uncovered line308 is the startup-while-background-paused ownership guard. This is changed executable-line coverage, not all branches/interleavings, native allocations, errno or devices. No extra test was added merely to mirror that guard.

Only two fresh final HOST profiles from one binary (XCTest discovery and Swift Testing host), individually validated, warning-free merge. Prior live codecov moved before test stamp and root default profiles excluded. llvm-cov used matching app --object; show/export stderr empty. No old/cross-layout merge or child coverage claim. Swift function hashes are zero in this toolchain and cannot prove layout compatibility; fresh runs, archived objects and source hashes establish the evidence scope.

Before/after hashes matched1,123 production Swift and804 test Swift files and both binaries, privately archived in `.build/semantic-scope-lifecycle-validation/final`:

- Test host SHA-256: `434a55f167a549e6399fee38411b34b4e75a3fa246f92cef2882ba8782c1cf96`
- App SHA-256: `bab485dfa8641ef32a7c40af414da766ddacc49e8711748412be5875eeed07ff`

## Limits

Private synthetic documents, placeholder models, injected readers/encoders/transfers/watchers and sinks only. Existing harmless shell-protocol fixture and injected URLProtocol failure test run without real weights/network. Production startup reads current FSEvents ID/private-root volume metadata with injected watchers, not a real watcher stream or home/TCC permission probe. Real models/CoreML/download/provider/network/home/network mounts/capture/mic/audio output/clipboard/external apps/full suite/signing/hardware excluded. No presentation/helper ABI/entry/packaging change in this increment, so no new screenshot/probe. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss immunity.
