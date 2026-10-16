# GUL-399: semantic model artifact mutation admission

Base: `df614100ce6c20fb73eaf7ad7a0917642d584914` (#575). This increment coordinates model mutation with the service's existing default native query, document-indexing and media owners. It does **not** register semantic health domains, change the helper ABI, or redo filename-index and reader retirement work.

## Behavior

`SemanticEmbeddingOwners.mutation` acquires a nonwaiting, explicit lease. Base-model mutation must acquire all three owners; projector mutation acquires only media. Each owner must have neither admitted host work nor an uncollected native child. Partial acquisition is released on refusal. While the lease exists, new native host work fails unavailable. An idempotent finish/deinit cannot accidentally release a later mutation. The short state locks never cross an await or filesystem call.

The service acquires the base-model lease **before starting a download**, and keeps it through the joined fetch, verification and install. A busy owner causes failure without fetching, producing a candidate, stopping another operation, queuing a retry or changing existing files. Explicit subsequent download can try again after retirement. The original lifecycle is checked before work and installation and after the awaited result. Model readiness is withdrawn during the attempt. Cancel before install can return to model-required; cancellation after install was dispatched reports failure because an uncooperative installer may already have changed the target. No rollback or automatic retry is claimed.

Lazy projector downloading uses the same media owner as the default encoder, including standalone `SemanticMediaWorker`. It acquires its lease before fetch and retains it until transfer/install returns. Read-only verification of an existing projector remains separate, and query/document lanes remain available during projector mutation. The service passes its existing owner composition; explicit injected factories retain responsibility for their own lifetimes.

Explicit `clear` still joins its existing work/download tasks and performs the existing two-second retirement check. It now acquires the same model-mutation lease immediately around deletion, closing the gap between checking idle and admitting another native user. Busy or unretired ownership preserves files. No clear, download, install, reindex or database mutation was added to recovery. Already committed partial indexing, filename/lexical fallback, selected scope, priorities and model consent remain unchanged.

`SemanticModel.install` now verifies the **copied staging bytes**, in addition to the earlier source verification. A private test changes the source between those steps and verifies that the existing target survives checksum rejection. Replacement uses `.usingNewMetadataOnly`, preserving the staging file's `0600` permissions instead of inheriting an older target's `0644`. This fixes a real failure found by the new test. Existing expected sizes/checksums and 4 MiB verification chunks remain.

## Boundaries and remaining work

This is per-service default-native ownership, not a global model-path lease across arbitrary services, custom factories or other processes. The filesystem is not an immutable transaction: alias retargeting, source/target replacement between checks, blocking verification/copy/rename, filesystem errors and power loss remain boundaries. Copy can consume disk before later size/hash rejection; no new aggregate disk quota or hard filesystem deadline is claimed. Read-only verification is not model loading and does not gain a global path reservation.

Existing download-temp and staging cleanup remain. This increment does not add durable failed-install receipts or candidate retention for every filesystem failure. Its new busy refusal occurs before fetch creates a candidate. Already-dispatched replacement may have effects despite cancellation/error; neither health nor retirement retries or undoes it. Explicit clear remains destructive only by the existing user action. The two-second check does not bound preceding joins, filesystem work, scheduling or whole-app quit.

No new executable, global worker, pool, full-DI initialization or per-view supervisor. Existing native host/child retirement, external newline ABI, pending-query limits and independent fault domains remain. Semantic health registration, broader condition-driven lifecycle and existing progress/idle queue backpressure are still required. No arbitrary host crash, systemwide OOM, native allocation, rollback or power-loss guarantee.

## Validation

Implementation and self-review preceded testing. **46 distinct focused methods** were exercised: initial **45/46** passed (10 XCTest, 36 Swift Testing), then the final affected scope **26/26** passed (5 XCTest, 21 Swift Testing). The sole failure was the real replacement-permission defect above: expected `0600`, observed inherited `0644`. Production was corrected only after the test and initial evidence archival completed. The other 20 initially passing methods were not repeated.

| Scope | Distinct methods | Final rerun |
| --- | ---: | ---: |
| SemanticArtifactOwnershipTests (new) | 5 | 5 |
| SemanticArtifactServiceTests (new) | 4 | 4 |
| SemanticEmbeddingOwnershipTests | 5 | — |
| SemanticEmbeddingServiceOwnershipTests | 2 | 2 |
| SemanticEmbeddingWorkerTests (safe fixtures) | 5 | — |
| SemanticFileServiceTests (safe fixtures) | 8 | 8 |
| SemanticMediaWorkerTests (safe fixtures) | 3 | 3 |
| SemanticMediaServiceTests | 4 | 4 |
| SemanticRealtimeSearchTests (safe fixtures) | 8 | — |
| SemanticPreparationServiceTests | 1 | — |
| SemanticIndexFairnessServiceTests | 1 | — |

New tests cover model/projector exclusion, rollback of partial admission, idempotent lease release, host and child retirement, refusal before fetch, explicit subsequent attempt without replay, staged-source mutation, replacement permissions, uncooperative install cancellation and retained target effects, old-scope revocation before work, and a default media worker with a real harmless shell child. Mapped compatibility covers clear retention, old native generations, query bounds/cache, lexical fallback, privacy and partial indexing.

Only private placeholder models/documents, injected transfers/encoders and harmless shell/Python helpers were used. No real weights/CoreML, model download, network/provider, home/network-mount scan, FDA/TCC probe, capture/microphone, audio output, user clipboard, paste/wheel or external app action. Real-model opt-ins were excluded. No full suite, full Xcode, Developer ID/notarization, hardware or performance validation. No presentation, packaging or helper-entrypoint change; no new screenshot or packaging probe.

Commands use `scripts/test_runtime.child_environment`:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l TypefluxPackageTests / Typeflux  # __llvm_covmap and __llvm_prf_cnts verified
native_environment/native_tools + swiftpm-testing-helper prebuilt inventory
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <scope>
```

Initial exact scope:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticArtifactOwnershipTests[./]|SemanticArtifactServiceTests[./]|SemanticEmbeddingOwnershipTests[./]|SemanticEmbeddingServiceOwnershipTests[./]|SemanticEmbeddingWorkerTests[./](?!realModel)|SemanticMediaWorkerTests[./](?!realImage|realMediaFiles)|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticRealtimeSearchTests[./](?!`real file)|SemanticPreparationServiceTests[./]|SemanticIndexFairnessServiceTests[./]|SemanticMediaServiceTests[./])
```

Final affected scope:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticArtifactOwnershipTests[./]|SemanticArtifactServiceTests[./]|SemanticEmbeddingServiceOwnershipTests[./]|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticMediaWorkerTests[./](?!realImage|realMediaFiles)|SemanticMediaServiceTests[./])
```

Builds **118.58 s** (inner 114.77) and **33.63 s** (inner 33.33), both passed. Prebuilt inventory **4.112 s**. Initial functional command **48.12 s** (XCTest 4.284, Swift Testing 22.334); final **49.46 s** (XCTest 0.008, Swift Testing 15.981). Tracked total **253.902 s**, excluding audit, archive/coverage extraction and platform delivery. No compile failures or discovery rebuild. Existing unrelated warnings remain. No Sources/test inputs changed after the final build; no simultaneous own SwiftPM/UI jobs.

## Coverage evidence

**70/70 changed executable lines (100%)** against the actual base: ownership 35, installer 5, service 21, media worker 9. The companion JSON records counters. Guard/definition line hits are not all-branch, errno, filesystem replacement, race, native allocation, real-model or device proof.

Only **three fresh final host profiles**, with one matching final binary/layout, contribute coverage. Every raw profile was individually validated; sparse merge was warning-free. The matching app/worker is included with `llvm-cov --object`. Initial three profiles are archived separately and excluded; no cross-layout merge. Persistent killed/collected children did not contribute profiles; there is no child-coverage claim. Inventory profiles are excluded.

Evidence: `.build/semantic-artifact-validation/final`:

- XCTest SHA-256: `23c94b9c67157137b5f613d0e99db65f96ff916d650186f8c6cf5650f412c95c`
- App/worker SHA-256: `43fab35b8c1a622754106b8a8157144128e3aa7804d5775c95b820530cbb6d04`

All production source hashes match archived inputs. Build/test/archive/merge/extraction commands were collected before dependent reads and edits. Existing macOS 13 deployment settings and the macOS 14 XCTest runtime are not macOS 13 Intel hardware proof. All run-owned jobs were collected. GUL-399 remains in progress.
