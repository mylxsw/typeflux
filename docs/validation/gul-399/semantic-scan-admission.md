# Semantic scan preparation admission

Validated base: main `040ca0e1cf16413f5b426c3c3e3424b7b263fd42`. Preserves bounded progress/watcher/pending intents, independent reader/model/native health budgets, original grants, eventID/volume signatures, targeted subtree pruning, durable partial queues, foreground priority/pause and lexical/filename fallback.

## Behavior and self-review

Discovery checks original cancellation before beginDiscovery, including standalone/resumed calls. Reconcile builds the same deduplicated/sorted candidate entries, then checks cancellation before its initial discovery/work-queue insert. Full indexing checks again after reporting the discovered summary and before invoking the discovery-receipt callback: a progress sink can revoke the original scope without allowing the next checkpoint write.

Startup retains its original entry guard and now rechecks the same token after access/scope preparation, before constructing SemanticFileStore. Access/scope work already entered can finish; an observed canceled scope cannot then create/open/migrate the content DB. Likewise a service factory already entered can finish, but the subsequent indexer preparation now checks the canceled source. Existing actor fingerprint/attempt guards still fence publishing and terminal/checkpoint continuations.

No retry, rollback, recovery deletion, new permission/health grant, helper/pool/full DI/global bypass, native probe/model preparation or callback-driven replay was added. Internal continuations keep original grants. This adds direct checks at preparation/receipt boundaries, not a transaction across settings, filesystem and SQLite. Reconcile's temporary input array remains outside global memory bounds; no producer scheduling/priority/pause behavior or actual inference is throttled.

Self-review before tests traced run/reconcile/direct discover, actual service startup/factory admission, discovery snapshot resets, failed-directory protection, work queue/committed content, checkpoint timing and progress cancellation. Already-committed discovery remains available for a later explicit operation; cancellation does not reset it or automatically rerun work. Existing interrupted-work/partial receipts and already-entered effects cannot be rolled back. Stable mutation identity remains required before any future write retry.

## Focused validation

Commands use scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit methods in semantic-scan-admission-methods.json>'
```

Prebuilt discovery used native_tools/native_environment/swiftpm-testing-helper, not XCTest as a program. Exact names/backticks recorded in methods JSON. **92/92 distinct methods passed on the first functional run**: one XCTest (0.011s) and91 Swift Testing methods in21 suites (32.382s).

Four new methods/seven cases cover:

- Pre-canceled run/discover/resume/reconcile preserving the private DB's row-change counter, committed files/chunks, discovery/work queue, pending/failed directories, scope/prune state and checkpoint, with zero reader/encoder/progress/receipt admissions.
- Cancellation from discovered-progress retaining the completed discovery and queued work but not invoking a checkpoint callback; a later explicit operation can resume and finish normally.
- Actual automatic service access held across a synchronous settings revocation, proving no semantic-files.sqlite files are created after release/collection.
- Actual service factory held across revocation, proving its already-open DB's prior discovery, failed-directory protection and old-volume checkpoint survive without a scan. This test compares committed metadata through a separate private connection; it does not claim startup performed no earlier schema/open work.

Existing actual service/indexer consumers cover partial committed index, targeted subtree/prune, checkpoint receipts, failed-obligation retention, bounded pending work, priority/pause, original download/count/progress/native health admission and lexical/filename/query permission fallback. Only the synthetic document-events-preempt SemanticMediaIndexTests method runs (four cases); real file/media/model/event/permission methods excluded. Safe shell-protocol cache/lazy-transfer fixtures only.

Build69.79s passed without changed-file warnings; unrelated warnings/native build-system deprecation remain. Inventory4.168s; test command61.07s; archive38.191s. Tracked build/inventory/test total135.028s (173.219s including archive) excludes extraction/audits/platform work. No functional retries, timeout relaxation or Source/test edits after build.

An evidence extraction was mistakenly launched while the archive command was still running/uncollected and failed. Both commands were collected, failed extraction outputs were excluded, and extraction was rerun successfully from the completed archive. Final coverage below uses only that completed archive; no Source/test/binary/profile inputs changed or functional tests reran during this correction. Extraction wall time, including the failed attempt, was not separately recorded.

## Coverage evidence

Changed executable lines vs stated base: **8/8 (100%)**, discovery2/2, indexer5/5, service1/1. This measures executable line coverage, not every branch, race, errno, native allocation or device.

Only three fresh final HOST profiles from one binary (XCTest discovery, selected XCTest execution, Swift Testing host). Every raw validated individually; merge warning-free; final llvm-cov show/export use matching app --object with empty stderr. Both binaries have __llvm_covmap and __llvm_prf_cnts. Prior live profiles/root default.profraw excluded. No old/cross-layout merge or child-process coverage claim. All2,552 Swift function hashes are zero and cannot prove compatible layouts; matching binaries and1,127 Source +810 test Swift hashes were verified before/after extraction. No new production Source file.

Private evidence .build/semantic-scan-admission-validation/final:

- Test host SHA-256: `164731bbb11744a7d6bbeb6f5b6848f5ecce1553837bf3a28bd81bf81bdb5010`
- App SHA-256: `e969473a2081abce895df54f65548cc433e11b51d03df7ffd6f3d6e341d2a5d6`

## Boundaries and remaining work

Checks prevent admissions when cancellation is observed there. They do not make settings/permissions, path normalization, file access and SQLite writes linearizable; an effect entered after a check cannot be rolled back. Concurrent settings writers/binding, direct defaults writes, separate defaults objects sharing a suite, external preferences/account/FDA conditions and broader feature/native/media lifecycle remain outside this increment. Health recovery stays availability-only; no automatic operation replay.

Private synthetic documents/models/readers/encoders/access/factories/FS/sinks/watchers only, harmless shell and injected URLProtocol. New service tests inject history/idle and never read real permissions; some existing fake-watcher tests read current eventID/private-root volume metadata, not real streams. No real weights/CoreML/provider/network/model download/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No own presentation/helper ABI/entry/package change, so no screenshot/copied packaging probe. Audio/TCC/signing/performance prerequisites precede microphone ownership; real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording unverified.

Concurrent main `7a83189d271a87b65e6bbc518edef43842d8c0f7` changes14 disjoint launcher-home paths after this binary's base. Preserve them at landing and verify actual main tree/ancestry; this binary does not include those changes, and independent home behavior/the whole newer main are not claimed tested. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; arbitrary host/native crash/OOM/power-loss immunity is not provided.
