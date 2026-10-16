# Original media operation admission

Validated base: main `f97b7918fb24e51fabf5e9853f797bbf75915b1b`. Preserves independent query/index/media/reader health budgets, original lifecycle grants, bounded UI/watcher/pending delivery, checkpoint/subtree pruning, partial queue, source permission and lexical/filename fallback.

## Behavior and self-review

SemanticMediaWorker checks its composed original cancellation before model verification, before delegating to a new or cached encoder, and after a successful native result before returning it. The initial immutable media-health authorization check remains first. No later input can inherit a recovered generation. The default model verifier opens a file and reads a batch before its internal cancellation check; the new entry guard prevents that initial read when cancellation is already observed at this boundary. A custom verifier/encoder that ignores cancellation can finish an entered operation, but cannot use that completion to prepare the next encoder or return a revoked vector.

The synchronous initial download-progress sink can revoke the original scope. A cancellation check after that sink and its terminal-reset defer prevents starting a transfer in that case. The existing projector mutation lease releases on this path, and nil progress reset remains reliable. There is no task per update and no new producer, helper, pool, full DI or global bypass.

Already-entered fetch/install/native operations retain their existing ownership and collection semantics. A source-revoked transfer still holds its projector mutation while its physical fetch is blocked; once it returns, the temporary file is removed and install/factory/native calls remain unentered. An install that has already entered can still change files; a successful return after cancellation does not prepare an encoder. No rollback, install/write retry, recovery deletion, readiness preparation, download/query/scan replay or new health grant was added. The changes do not serialize settings, filesystem and SQLite into a transaction.

Self-review before testing traced cold/cached paths, verify success/failure, factory side effects, post-native return, synchronous progress callbacks, mutation release and the semaphore transfer collection. It also audited service detached startup and indexer run/reconcile/discovery entry. Their initial scan preparation and mutation boundaries remain a separate increment: discover's beginDiscovery and reconcile's initial discover occur before their inner cancellation checkpoints. A service entry guard before factory construction is not atomic with later FS/SQLite work. Existing interrupted-work/partial receipts and event checkpoint/prune semantics are unchanged.

## Focused validation

Commands use scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit methods in semantic-media-admission-methods.json>'
```

Prebuilt discovery used native_tools/native_environment/swiftpm-testing-helper, not XCTest as a program. Exact names/backticks are recorded in methods JSON. **82/82 distinct methods passed on the first functional run:** one XCTest (0.012s) and81 Swift Testing methods in17 suites (23.395s). Seven new methods/nine cases cover pre-canceled cold/cached calls with zero model/factory/native admissions; cancellation during successful/failed verification; factory cancellation; canceled native completion with cold/cached encoders; synchronous progress revocation with terminal nil and released mutation; already-entered install preserved without encoder preparation; and a held source-revoked transfer retaining mutation until actual completion, without install/native work or leaked temporary file.

The held transfer fixture deliberately ignores cancellation, but its gate is released explicitly by the test; this is not a proof of arbitrary provider termination or every Task cancellation interleaving. Existing failed/canceled transfer, lazy download/reuse and shell-protocol embedding cache tests passed. The single XCTest verifies pre-ready/recovered media permissions cannot download using the old grant. Selected actual service/indexer consumers cover lifecycle/count/progress/download ownership, priority/pause/media boundaries, partial committed index, source/query permissions and lexical/filename fallback. SemanticMediaIndexTests is restricted to the synthetic document-events-preempt method (four cases); real-file/media/model/event/permission methods are excluded.

Build277.58s passed without changed-file warnings; unrelated existing warnings/native build-system deprecation remain. Inventory4.645s; focused command47.03s; archive1.957s. Tracked build/inventory/test total329.255s (331.212s including archive) excludes extraction/audits/platform delivery. No retries, production timeout relaxation, or Source/test input edits after the build.

## Coverage evidence

Changed executable lines vs stated base: **9/9 (100%)**, all in SemanticMediaWorker. This measures changed executable lines, not every branch, race, errno, native allocation or device.

Only three fresh final HOST profiles from one binary: XCTest discovery, selected XCTest execution and Swift Testing host. Every raw individually validated; profile merge warning-free; llvm-cov show/export use the matching app --object with empty stderr. Both app/test binaries contain __llvm_covmap and __llvm_prf_cnts. Prior live profiles and root default.profraw excluded. No old/cross-layout merge or child-process coverage claim. All2,488 Swift function hashes are zero, so hashes cannot prove compatible layouts; matching objects and1,127 Source +809 test Swift hashes were verified before/after extraction. No new production Source file in this increment.

Private evidence .build/semantic-media-admission-validation/final:

- Test host SHA-256: `3abf1b1c369254d5a6fea660d0d0c67ff80aff3d359095de9603ab50f72275b0`
- App SHA-256: `d172a8abbb70e1458cbf7d2a2d2898516ce02b6e74e3465ad51ec44d585586ea`

## Limits and remaining work

Cancellation observed at a boundary prevents that admission; cancellation after a check cannot atomically undo an entered filesystem/native effect. Physical work remains owned through collection. Custom standalone factories retain their own serialization, cleanup and source-consent responsibilities. Scan/startup pre-mutation admissions, stronger concurrent settings/condition-source ordering, direct preferences changes and OS FDA/account transitions remain subsequent work. Stable mutation identity is required before any future write retries. Existing bounded queues do not cap every native array/configuration/normalization temporary or persisted DB result.

Private synthetic documents/models/readers/encoders/transfers/FS/sinks/watchers only, harmless shell protocol and injected URLProtocol. New media fixtures use placeholder bytes, fake vectors and an unread private path; no real model/media decoding. Some existing fake-watcher fixtures read current eventID/private-root volume metadata, not real streams or permission probes. No real weights/CoreML/provider/network/model download/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No own presentation/helper ABI/entry/package change, so no screenshot or copied packaging probe. The current icon baseline is compiled without claiming independent icon behavior validation.

Broader native/media/feature lifecycle remains; audio/TCC/signing/performance prerequisites precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; arbitrary host/native crash/OOM/power-loss immunity is not provided.
