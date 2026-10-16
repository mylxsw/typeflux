# Bounded semantic watcher handoff

Base: main `5a6c9be513b066943274d3fffd5b3807802c4f00`. Preserves worker health/download/index progress prerequisites, discovery checkpoints/targeted subtree pruning and hidden progress rows. This increment bounds watcher-to-actor delivery, not all index pending work.

## Behavior and review

A dedicated SemanticWatcherDelivery replaces Task-per-event-batch handoff. Producers use the immutable original scope/index directory and cancellation token to plan pure paths off the UI delivery path. Plans union file and directory obligations, including renamed parents; receipts retain the maximum event ID even for ignored/empty batches. No raw event array is captured by a queued UI task. Planning happens outside the short state lock, and never waits for actor execution or performs FS/DB/model work.

Each local/pending plan retains at most512 combined file/directory paths and128KiB of UTF-8 path payload. Over count or byte capacity, it releases targeted paths and retains a full-scope catch-up obligation plus the highest receipt. Full catch-up semantically supersedes targeted work; this preserves reconciliation obligations, not a historical event log or every intermediate filesystem state. It routes through the existing dirty/fullScan policy, after active indexing has finished or existing pause conditions permit reconciliation. No new producer pause/restart/throttle, write retry or inference replay mechanism was added. Within the targeted budget, existing document priority behavior is unchanged; no performance claim is made for an overflow catch-up.

There is at most one queued MainActor delivery plus an active synchronous sink, shared across source replacement/invalidation. A sink-time offer retains one follow-up slot. Original source identity is checked before and after planning; cancellation is also checked before delivery, and the existing service original token/settings guard runs before pending-state mutation. Start/clear/deinit invalidate the handoff. A stale source cannot adopt a new source's receipt or work plan.

Delivery itself never acknowledges a receipt. Existing service/database processing retains responsibility: targeted work commits its receipt after reconciliation; full catch-up invalidates the old discovery checkpoint, then records the new start receipt only after discovery obligations have been made durable. Existing partial queues/failed-directory/prune semantics remain unchanged. Tests hold real private work at those boundaries to verify no premature acknowledgement. Event history is a narrow constructor dependency for deterministic receipt tests; production still calls the same FSEvents current ID and volume-signature functions at the same startup point.

Self-review before focused tests covered union/deduplication, count/byte overflow and fullScan dominance, original source checks, active-sink invalidation, empty receipts, actual consumer checkpoint ordering and existing priority/pause/fallback paths. No health grant or recovery-triggered scan/preparation/download/query was added, and internal continuations retain original grants. No helper/pool/fullDI/global test bypass or permission transaction was introduced. Already-entered effects cannot be rolled back.

## Focused validation

Direct commands used scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit methods in semantic-watcher-delivery-methods.json>'
```

Prebuilt inventory used native_tools/native_environment/swiftpm-testing-helper, not XCTest as a program. Both app/test binaries have __llvm_covmap and __llvm_prf_cnts. Exact method identifiers including backticks are in the methods JSON.

**84/84 distinct Swift Testing methods in20 suites passed on the first functional run**,27.724s execution. No XCTest test methods ran. Eight new methods:100,000 off-actor producer callbacks with held delivery and unioned obligations/max receipt; exact capacity, count/byte overflow and fullScan dominance;1,000 source replacements sharing one slot; cancellation/revocation/sink follow-up; actual held targeted processing; overflow requiring held catch-up discovery; replacement/clear and current empty receipt; settings changed before delivery. Existing startup/async completion fencing, download consent/admission/uncooperative install, progress/count ownership, checkpoint restart/manual rescan/targeted subtree pruning, partial index, priority/pause and lexical/filename/query permission compatibility passed.

Build249.81s passed with no changed-file warnings; existing unrelated warnings/native-build deprecation remain. Inventory5.494s; focused command55.33s; archive4.654s. Core tracked build/inventory/test total310.634s excludes archive/extraction/audit/platform delivery. No retries or production timeout relaxation; no Source/test edits after build.

## Coverage and evidence

Changed executable lines vs the stated base: **83/83 (100%)**, change-plan18/18, service19/19, mailbox46/46. This measures changed executable lines, not all branches, interleavings, errno, native allocations or devices.

Only two fresh final HOST profiles from one binary (XCTest discovery and Swift Testing host). Each raw validated, warning-free merge; prior codecov moved before the test stamp and root default profiles excluded. llvm-cov used matching app --object; show/export stderr empty. No old/cross-layout profile merge or child coverage claim. Swift function hashes are zero and cannot prove layout compatibility; fresh matching objects and verified source hashes establish evidence scope.

Before/after hashes matched1,124 production Swift files,806 test Swift files and both binaries, privately archived at .build/semantic-watcher-delivery-validation/final:

- Test host SHA-256: `90030c6ba53d0b790aa0c6c109a4756bcbd271018815017f9e7b4f251bf03051`
- App SHA-256: `b0fc332a59e577ef56ff74ddf84e365409af2f1975cf638443191332102f0dba`

## Remaining limits

The native input array, immutable source configuration, service pendingPaths/pendingDirectories and SemanticIndexPauseGate document queue are outside this handoff bound. An active sink and active producer may each hold another bounded plan. It is not an end-to-end heap cap, immutable FS snapshot or synchronous permission revocation for already-entered off-actor workers. Service/pause-gate pending-work capacity and stronger producer authority ordering remain explicit subsequent work.

Only private synthetic documents, placeholder models, injected readers/encoders/transfers/watchers/history/schedulers/sinks and an existing harmless shell-protocol fixture were used. Injected URLProtocol failure tests do not use network. New receipt fixtures avoid OS event-history reads; existing service fixtures still read current FSEvents ID/private-root volume metadata with injected watchers, not real watcher streams or home/TCC probes. No real weights/CoreML/provider/network/model downloads/home/network mounts/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. Real model/media/event/permission suites excluded. No presentation/helper ABI/entry/package change, so no new screenshot/copied probe. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
