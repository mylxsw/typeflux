# GUL-399: independent semantic file-reader health

Base: `f186c0de063c358bea8db6763dd911b01deca6fe` (#576). This increment registers the existing three semantic **file-reading** lanes. Semantic model query/document/media inference remains separate and is not registered by this change. Filename-index health and previous retirement/artifact work are retained.

## Behavior

`SemanticReaderModules` retains three independent adapters, reusing `ModuleHandle`, `ModuleWorkerGate`, supervisor, registry and bounded/content-free health store:

| Lane | Module ID / health filename |
| --- | --- |
| File validation | `semanticValidation` / `semanticValidation.json` |
| Discovery and content reading | `semanticIndexReading` / `semanticIndexReading.json` |
| Priority documents | `semanticPriorityReading` / `semanticPriorityReading.json` |

DI adds these to the existing sixteen registrations. Each persistent reservation is once per factory generation, not per request, directory, file or child. Corrupt health is preserved until explicit reset. No opt-in to main's storage-only automatic quarantine reset is added. Readiness checks executable availability off the UI actor and the **same** lane's occupancy. It never launches a probe, checks FDA, loads a snapshot/model, scans, resolves, embeds, downloads, rebuilds or writes index data. Typed reads bypass the generic supervisor operation timeout.

The same lazy reader and native lineage remain. Health cleanup immediately fences scopes and signals only the thread-safe process stop handle. Coalesced serial cleanup and a lifecycle queue barrier keep reader FD/buffer access on its owner. Cleanup then awaits actual native retirement. An uncooperative factory, consumer, descriptor cleanup or uncollected child retains capacity; a two-second default supervisor cleanup deadline cannot authorize replacement. One coalesced event observer per lane retains the failure generation separately. Duplicate adapter release cannot stop the first owner. No new executable, pool, global worker, per-view handle, full-DI helper construction or task per response was added.

The scoped reader captures its original health generation, checks it before/after native work and immediately around callbacks, and cannot acquire a later generation's permission. The production shared service requires lifecycle readiness; independent constructors retain explicit injection seams and the existing XCTest privacy guard. The service records reader capability generations at an explicit start/configuration transition. Internal watcher reconciliation, pause continuation and post-download startup retain those generations. A pending watcher task cannot mint new permission after health recovery; existing explicit recheck/restart can establish a fresh service scope. Health readiness is not root/account/FDA authorization.

Initial application startup calls the testable `startForApplication(using:)` entry point after registry startup, with cancellation checked before the feature start. It is not registered as a health factory or recovery callback. Readiness recovery never calls it. Standalone tests verify this ordering without DI or hardware. A healthy watcher full scan still works; a pending full scan spanning disable/recovery stays fenced.

Valid response `.error`, nonlocal mount/capacity refusal and cancellation remain distinct from faults. Native timeout, missing response/EOF, malformed JSON and frame-size/transport failures use the existing native ownership fault path. The adapter also classifies explicit injected decoding/protocol/timeout failures. POSIX launch/configuration `EACCES`, `EPERM`, `ENOENT`, `ENOEXEC` waits for explicit recovery. No raw errors or paths enter health persistence. The newline ABI still has **no UUID/version envelope**; this does not claim identity validation or change the external semantic helper ABI.

The original 8 MiB receive frame, five-second idle/default startup up to thirty seconds, progress reset and **no total deadline for advancing directories** remain. The existing 250 ms collection grace, sixteen-physical-child reaper ceiling, owned PID/group signaling and low-QoS restrictions remain. The new lane cleanup never waits for a consumer or filesystem work on the UI actor or global reaper; existing feature filesystem boundaries remain. State observation uses a separate short host-activity flag; it never competes with the nonwaiting reader operation lock.

Health cleanup never calls service clear/turn-off or deletes snapshots, databases or models. Cached filename/lexical fallback, original source/root/exclusion/FDA/account/generation rules and already committed partial indexing remain. Already-entered callback effects or dispatched writes cannot be rolled back. Model artifact admission, unknown encoding candidates and publication receipts are untouched. Recovery adds no automatic scan, query, model work, write or producer replay.

Remaining boundaries include independent model inference adapters, progress/idle task backpressure, broader feature/condition integration, filesystem and SQLite behavior, host allocation/JSON/UI/AppKit/GPU and uncooperative callbacks. There is no new global bound across arbitrary service instances or custom factory lifetimes. Readiness is not native format, signing, permission or hardware proof. No arbitrary host crash, systemwide OOM, power-loss cleanup, rollback or whole-app quit guarantee.

## Validation and failure history

**75 distinct focused methods were exercised across mapped passes.** Initial 74: **73 passed**, with one real defect in the new implementation: `isOccupied` briefly took the operation lock, allowing a concurrent status observation to make a normal read fail unavailable. Replaced that observation with a protected activity flag, added a bounded concurrent-observation/300-read regression, and **21/21 affected methods passed**.

Coverage review then exposed an inadequate watcher fixture: its change path was inside the ignored index directory. Corrected it to a document outside a nested index directory, verified both healthy full scans and post-recovery suppression, and tested the actual application-startup entry point including cancellation. The next mapped **37/38 passed**. The sole failure was an existing ownership fixture assuming callback return meant asynchronous cleanup had finished. Its immediate next read correctly failed busy. The fixture now waits for actual lane retirement before requiring admission; production capacity/deadlines were not weakened.

Final same-binary scope: **29/29 passed (19 XCTest, 10 Swift Testing)**. It includes the failed method plus mapped adapter/startup/consumer scopes needed for final coverage. No full-suite retry, compile failure or source/test change after the final build. Other mapped passing methods were not unnecessarily repeated.

| Scope | Distinct methods | Final pass |
| --- | ---: | ---: |
| SemanticReaderModuleTests (new) | 9 | 9 |
| SemanticReaderHealthViewTests (new) | 2 | 2 |
| SemanticReaderOwnershipTests | 9 | 1 affected method |
| SemanticReaderServiceTests | 1 | Earlier mapped passes |
| AskFileReaderRetirementTests | 9 | Initial mapped pass |
| FileIndexModuleTests | 9 | 9 |
| SemanticFileServiceTests (safe methods) | 8 | 8 |
| SemanticRealtimeSearchTests (safe methods) | 8 | Initial mapped pass |
| ModuleRegistryTests | 12 | Initial mapped pass |
| ModuleHealthStoreTests | 6 | Initial mapped pass |
| StorageModuleRegistryTests | 1 | Initial mapped pass |
| LocalizationResourceTests (one mapped method) | 1 | Initial mapped pass |

Tests cover separate files/budgets, once-per-generation reservations, corrupt preservation and clock/reset, expected refusal versus protocol fault, all four configuration errnos, native crash/truncation/timeout, original scope generation, blocked host/factory with no replacement, late attach/delayed collection, duplicate/owner release, disable/recover/quit, consumer rejection of late success, cancellation and no read/scan replay. The actual settings restore buttons for all three rows were exercised without a reader request. The final 640×370 screenshot was inspected; all labels/buttons/footnote are visible.

Only private directories/documents, synthetic protocol payloads, injected readers/models/transfers and harmless shell/Python children were used. The actual built main executable's file-worker entry resolves private fixtures. No real home/network-mount scan, FDA/TCC probe, weights/CoreML/model download, network/provider, capture/microphone, audio output, user clipboard, paste/wheel or external app action. Real-model/media opt-ins were excluded. No full suite, full Xcode, Developer ID/notarization, device or performance validation. Helper ABI/entrypoint/packaging is unchanged; no new packaging/copied-bundle probe.

## Commands and timing

Scripts use `scripts/test_runtime.child_environment`. Direct builds and tests:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l TypefluxPackageTests / Typeflux  # __llvm_covmap and __llvm_prf_cnts verified
native_environment/native_tools + swiftpm-testing-helper prebuilt inventory
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <scope>
```

Initial exact filter (74 prebuilt methods; one later compiled regression adds the 75th):

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticReaderModuleTests[./]|SemanticReaderHealthViewTests[./]|SemanticReaderOwnershipTests[./]|SemanticReaderServiceTests[./]|AskFileReaderRetirementTests[./]|FileIndexModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticRealtimeSearchTests[./](?!`real file)|LocalizationResourceTests[./]testLauncherGeneralAndInputSourceCopyExistsInEveryLanguage)
```

The 21-method correction selected new module/UI, reader ownership and reader service suites. The 38-method bootstrap pass added filename-index and safe file-service scopes. Final exact filter:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticReaderModuleTests[./]|SemanticReaderHealthViewTests[./]|FileIndexModuleTests[./]|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticReaderOwnershipTests[./]testUncooperativeConsumerRetainsLaneAndRejectsLateSuccess$)
```

Five builds passed: **233.48 / 74.17 / 53.82 / 54.42 / 44.52 s** (inner 229.64 / 73.87 / 53.47 / 54.06 / 44.19). The first two preceded functional testing; self-review added service-generation fencing before the first test pass. Prebuilt inventory **8.793 s**. Functional commands **55.41 / 33.98 / 27.10 / 23.27 s**; final XCTest **6.658 s**, Swift Testing **6.610 s**. Tracked total **608.963 s**, excluding source/platform audit, archival/extraction and image inspection. No discovery rebuild or simultaneous own SwiftPM/UI jobs. Existing unrelated warnings remain.

## Final coverage evidence

**137/143 changed executable lines (95.80%)** against the actual base. New adapter 50/50, reader lane 67/67, native wait extraction 3/3, service 17/18. Six uncovered lines are the three AppCoordinator forwarding lines, two DI composition lines and the pause-continuation fallback at service line 167. Full DI/app startup was not invoked to hit those bridges; its extracted startup behavior was tested directly. Enum/static/resource declarations have no added executable counters.

Only **three fresh final host profiles**, with one matching final binary/layout, are used. All raw profiles were individually validated and sparse merge was warning-free. Matching app/worker included with `llvm-cov --object`; new Sources marked intent-to-add for diff coverage. Initial, correction and bootstrap profiles are separately archived and **excluded**. There is no cross-layout merge, prior-run reuse or child-coverage claim; killed/collected persistent children did not emit profiles. Inventory profiles are excluded.

Evidence: `.build/semantic-reader-health-validation/final`:

- XCTest SHA-256: `ec5772965ddcf25abac064ad67308fbc8eb657e73b27c435cf2f4090d7b003ca`
- App/worker SHA-256: `ffb475ebe0de497f7cfc08b6db553ef5d209347edc2682ac8a894d21db5f187a`

Production Swift source hashes match archived inputs. Build/test/children/archive/copy/merge/extraction commands were collected before dependent reads and edits. Existing app macOS 13 deployment settings and the macOS 14 XCTest runtime are not macOS 13 Intel hardware proof. Counter hits are not all-branch, errno, allocation, race, signing, actual shutdown or native/device proof. All run-owned jobs were collected. GUL-399 remains in progress.
