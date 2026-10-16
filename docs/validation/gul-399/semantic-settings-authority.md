# Semantic settings revoke original producer authority

Validated base: main `8bc1d607fa69ad4f4af4b8df179733603d8e9515`. Existing health budgets, bounded progress/watcher/pending intents, event checkpoints, subtree pruning, partial queues, source policy and fallback remain intact.

## Behavior and self-review

Three accepted SettingsStore setters now synchronously emit an immutable prospective-scope receipt before persistence: semantic enablement, filename search enablement and launcher file-index scope. The ordinary launcher notification remains after persistence. An automatic semantic service consumes the receipt synchronously through its own short-locked revocation slot; it reads no actor-owned settings and only cancels the original token. Existing detached readers, encoders, downloads and index work retain that token and their original health authorizations. This signal does not start work, grant permission or retry an operation.

Receipts have process-local monotonic revisions. Each lifecycle bind records the current receipt watermark; old, repeated or out-of-order receipts cannot revoke a later bind. The slot retains only the current token/fingerprint. No receipt/path content is persisted or added to diagnostics. A -> B -> A settings edits leave the original token revoked; the existing queued start now recognizes that canceled token even when the final fingerprint matches, so the current explicit settings transition can establish its own lifecycle. Later ordinary notifications are idempotent once the current scope has started. No-op, icon/fuzzy/calculator/browser/keyword edits do not revoke semantic work.

Only automaticStart services subscribe. A SettingsStore alias sharing the exact UserDefaults object (including standard defaults in production) is recognized, while foreign defaults objects are ignored. AutomaticStart=false and standalone/custom factories retain their explicit transition and cancellation responsibility. Existing immutable original grants remain on internal continuations; health recovery remains availability-only. No new pool/helper/full DI, worker retry, install retry, deletion for recovery, readiness preparation, scan/query replay or side-effect replay was added.

Self-review before functional tests traced all launcher notification post sites, the three scope setters, start/bind/clear/deinit, original reader/model/index/download cancellation capture and downstream checkpoint/pause consumers. Lock order is revocation slot -> revision sequence / token; receipt generation releases the sequence lock before notification delivery, and cancellation has no callback into settings. Subscription captures the revocation slot and defaults, not the service; existing weak actor-start subscription and deinit cleanup remain. Foreground/query pressure counts and physical task/native/mutation collection are unchanged.

## Validation

Commands use scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit methods in semantic-settings-authority-methods.json>'
```

Prebuilt discovery used native_tools/native_environment/swiftpm-testing-helper, not XCTest as a program. The exact inventory includes literal backticks. **104/104 distinct Swift Testing methods in25 suites passed on the first functional run** (27.743s execution); no XCTest methods ran. Six new methods/eight parameterized cases hold a real private indexing consumer while MainActor blocks, have the worker sample its original cancellation before any actor continuation, and cover all three accepted edits, shared-defaults aliases, same-fingerprint round trips, old/reordered/duplicate receipts, no-op/irrelevant/foreign edits and automaticStart=false compatibility. A direct setter observer verifies cancellation precedes persistence. The replacement scope remains searchable after old-receipt delivery.

Two existing launcher setter consumer methods and five semantic policy methods cover settings persistence/ordinary notifications; other selected consumers cover original download/count/progress lifecycle, lexical and filename fallback, permission gating, partial committed index, checkpoint ordering, bounded pending obligations and priority/pause/media boundaries. SemanticMediaIndexTests is restricted to the synthetic document-events-preempt method (four parameterized cases). Real-file/media/model/event/permission methods are excluded, not exercised as opt-in skips.

Initial build262.76s passed with a new test-only UserDefaults Sendable capture warning. Before the first functional run, the fixture changed to ObjectIdentifier comparison and injected idle=true; final build48.88s passed without changed-file warnings. Existing unrelated warnings and native build-system deprecation remain. Inventory5.912s; test command49.72s; archive3.212s. Tracked build/inventory/test total367.272s (370.484s with archive) excludes extraction/audits/platform work. No functional retries, production timeout relaxation, or Source/test edits after the final build.

## Coverage evidence

Changed executable lines versus the stated base: **48/48 (100%)**: authority31/31, service11/11, SettingsStore+Agent5/5, semantic settings1/1. This is line coverage, not every branch/interleaving, native allocation, errno or device.

Only two fresh final HOST profiles from one binary: XCTest discovery and Swift Testing host. Every raw validated, merge warning-free, llvm-cov show/export use the matching app --object with empty stderr; both binaries have __llvm_covmap and __llvm_prf_cnts. Prior live profiles and root default.profraw excluded. New Source was git-add -N before diff coverage. No old/cross-layout merge or child coverage claim. All2,424 Swift function hashes are zero, so hashes cannot establish layout compatibility; matching binaries and1,127 Source +808 test Swift file hashes were verified before/after extraction.

Private evidence .build/semantic-settings-authority-validation/final:

- Test host SHA-256: `5aa3074313b4f71e5a4e4f90fd01ed06b3a6c1c30d01b426e14e707f2fbe31ae`
- App SHA-256: `78e193d7bf57ad311a9affc10599ec4dbc032bac0a7086466219646d612d314f`

## Boundaries and remaining work

This is a settings-setter revocation prerequisite, not a linearizable settings/filesystem/SQLite permission transaction. Concurrent settings writers versus lifecycle binding, direct UserDefaults writes, distinct defaults objects sharing a suite, external preferences/account/OS FDA changes and stronger condition-source ordering remain outside this synchronous signal contract. Existing actor fingerprint fences still apply. Cancellation stops future cooperative admissions; already-entered reads/writes/native effects cannot be rolled back, and physical owners remain occupied through actual retirement. Native/media operation-entry and condition lifecycle audit remains, followed by broader feature lifecycle work. Stable mutation identity is required before any future write retry.

Only private synthetic documents/models/readers/encoders/transfers/FS/sinks/watchers, harmless shell fixtures and injected URLProtocol. New tests inject deterministic event history/idle; some existing fixtures read current FSEvents ID/private-root volume metadata with fake watchers, never a real event stream or permission probe. No real weights/CoreML/provider/network/model downloads/home/network mount/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No own presentation/helper ABI/entry/packaging change, so no screenshot/copied probe. Audio/TCC/signing/performance prerequisites precede microphone capture ownership; real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified.

Concurrent main `08cb830643a5f8d8fe6712ac1be0b653637855cc` modifies five disjoint icon paths after the validated base. This binary includes the earlier icon baseline by compilation, not that newer change; independent icon behavior and the whole newer main tree are not claimed tested. Landing must preserve those paths and verify the actual main ancestry/tree. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; arbitrary host/native crash/OOM/power-loss immunity is not provided.
