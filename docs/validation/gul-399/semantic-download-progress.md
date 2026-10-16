# Semantic model download progress and attempt ownership

Base: main `e856d24510907f56ee0ac9eba1e1e3355a34c2b3`. This increment follows the integrated health/index-progress work; it does not reopen the old PR chain.

## Behavior and review

Text-model fetch callbacks now offer absolute fractions into a dedicated bounded mailbox: one latest scalar, one scheduled MainActor delivery plus an active synchronous sink, shared across cancellations/replacements. Producers take a short lock and never wait for UI execution. Fractions clamp to 0...1. The existing indexing summary/path/media mailbox remains unchanged; its cumulative summary semantics do not fit this scalar channel. Both use the previously validated scheduling pattern. No producer, inference, count read, database write or filesystem install runs through either mailbox.

A download captures its original source identity, lifecycle token and settings fingerprint. Progress, pre-install admission and final completion check that ownership; progress also checks task cancellation. Cancellation synchronously seals the mailbox, but retains the physical task slot and model mutation lease until the actual fetch/install returns. Only that attempt can retire its slot. Failure/success seal progress before terminal state. Late callbacks cannot resurrect downloading after ready/failure/off or publish into a replacement.

An explicit replacement start cancels the old download and waits for its actual collection before preparing the new lifecycle, rather than returning with a revoked download still occupying the slot. The old result cannot install after fetch revocation or restart indexing in the new scope. A settings edit is checked even before its notification arrives. The async prepare-model action also retains its original lifecycle/settings and cannot carry cancelled or old-scope download consent across its await. A fresh explicit action can download normally.

Self-review included the fetch/install suspension boundaries, deferred slot cleanup, cancellation before task entry, idempotent mutation finish, clear/deinit, settings and background activity callers, explicit post-download continuation and health grants. Already-entered install effects cannot be rolled back; the existing unknown-effect policy and actual mutation admission remain in force. No install retry, model/DB deletion for recovery, health-triggered preparation, source/model consent grant or new pool/DI layer was added. Existing query/index/media/reader budgets remain independent. Broader watcher/rescan/permission lifecycle ownership remains subsequent work.

## Focused validation

Implemented and self-reviewed before testing. Direct commands used `scripts/test_runtime.child_environment`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope in semantic-download-progress-methods.json>'
```

The checked-in JSON lists the exact prebuilt method inventory, including literal backticks. Discovery used `native_tools`, `native_environment` and `swiftpm-testing-helper`, not the XCTest binary as a program. Both app/test binaries contain `__llvm_covmap` and `__llvm_prf_cnts`.

**64/64 distinct Swift Testing methods in 15 suites passed on the first functional run** (24.184s execution; parameterized cases remain method counts). No XCTest test methods ran. Ten new methods cover 100,000 producer events, 1,000 replacements with held UI delivery, latest scalar, producer offers during sink, terminal seals, actual service success/failure, clamping, cancelled and stale async preparation, uncooperative fetch cancellation, retained physical/mutation admission, old producer after fresh attempt, replacement start, disable/re-enable, settings edits before notification and clear. Existing uncooperative entered-install, occupied model refusal and explicit retry, partial committed index, foreground priority, pause, targeted reconciliation, filename/lexical fallback and query permission compatibility passed.

Build one passed in 315.55s; review then added the async preparation fence and two tests before any functional test. Build two passed in 86.41s. No Source/test inputs changed after the second build. No changed-file warnings; unrelated existing repository warnings and SwiftPM's native-build deprecation remain. Inventory 8.023s; focused command 50.29s. Core tracked total 460.273s; archive 3.015s separately. Extraction/audits/platform delivery are outside those timings. No retries or production timeout relaxation.

## Coverage evidence

Changed executable lines vs the stated main base: **86/86 (100%)**, service 50/50 and mailbox 36/36. This measures changed executable lines, not every branch, interleaving, native allocation, errno or device.

Only two fresh final HOST profiles from one binary were used (XCTest discovery host and Swift Testing host). Earlier live codecov outputs were moved out before the test stamp; root default profiles were excluded. Each raw profile was individually validated; merge was warning-free. llvm-cov used the matching app object, with empty export/show stderr. No old or cross-layout profile merge, and no child-process coverage claim. Swift function hashes are zero in this toolchain; freshness, matching archived objects and verified source hashes provide the layout evidence instead.

Archived privately at `.build/semantic-download-progress-validation/final`. Before/after hashes match for 1,124 production Swift files and 803 test Swift files, and for both binaries:

- Test host SHA-256: `83d33fee3ca704c17074a4a866ffac0592dd8985dc8e4d144257f6002ac2d1c8`
- App SHA-256: `45f244ece07c34142fb675edec7b26bc50e0be19d6741166c29f749be520e741`

Per-file coverage is in `semantic-download-progress-coverage.json`. Source/test inputs remained unchanged through archive and extraction.

## Scope limits

Only private synthetic documents, placeholder models, injected readers/encoders/transfers/schedulers and a harmless existing shell-protocol fixture were used. URLSession failure tests use an injected URLProtocol, not the network. Excluded actual model/checksum/download, real media/permission/event suites, provider/network/home/TCC/capture/mic/audio output/clipboard/external apps and the full suite. No helper ABI/entry/packaging or presentation change, so no new packaging probe or screenshot. No real CoreML/model performance, signing/notarization, macOS 13 Intel hardware or actual quit-recording proof. Host filesystem/JSON/SQLite/UI/AppKit/GPU/system memory remain boundaries; this is no arbitrary host/native crash, OOM or power-loss guarantee.
