# GUL-399 semantic model inference health

Base: `ccfd9db208d3a9fc8dc0f7e048bf3691ca6eb317` (#577). This change is stacked on semantic-reader-health, not main. Main remains `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`; its storage-only automatic quarantine reset, chat and background-task changes are outside this feature tree. No PR was merged. Other domains remain explicit-reset.

## Delivered behavior

Three fixed independent roles reuse the existing `SemanticEmbeddingOwners`: query → `semanticQueryInference.json`, document indexing → `semanticIndexInference.json`, media → `semanticMediaInference.json`. DI retains three adapters; the registry has 22 entries. No new helper, global pool, per-view handle or full-DI test setup.

Each factory checks executable availability off UI and the SAME owner's actual idle state. It never launches a probe, prepares/loads a model, verifies weights, downloads, embeds, scans or writes the index. Persistent reservation occurs once per factory generation, not per query, client, chunk or model operation. Existing content-free bounded persistence, corruption preservation and explicit reset apply. Availability is not model, resource, signing or device proof.

The owner binds the existing native lineage to `ModuleWorkerGate`. Health cleanup signals only the thread-safe owned process handle and awaits the current host/mutation admission plus actual child collection. A two-second supervisor cleanup deadline cannot free or replace an occupied owner. FD/cache mutation remains on the reader's serial owner. Status reads use the short state lock, never an operation try-lock. One coalescing observer retains faults separately; no per-response observer tasks.

Every worker captures its original health generation. Typed admission, cache access, queued preparation and final delivery cannot inherit a recovered generation. The service captures query/index/media grants only on its existing explicit start/settings transition; internal watcher, pause and post-download continuations retain the old grant. Lazy projector work checks that same grant, including cancellation while verifying/downloading. Recovery itself cannot prepare, embed, download or replay old input. Existing explicit caller preparation remains a feature action.

The external helper's existing newline ABI is unchanged (no UUID/version envelope). Structurally valid `error` replies without promised vectors are controlled model/native/input refusals, not transport crashes. `EINVAL` media refusal retains its unreadable outcome. Invalid count/dimension/norm/nonfinite vectors and mixed error+vector responses fault the role. Existing reader EOF/timeout/JSON/framing/transport classification and launch EACCES/EPERM/ENOENT/ENOEXEC condition handling are reused. Native model initialization currently exits without a typed reply on failure: that EOF is conservatively an unconfirmed transport fault, not proof of a crash or no model loading. No query retry was restored.

Model/projector mutation admission stays independent of health availability. Explicit management is allowed when no actual host/child lease exists; a factory cannot overtake an occupied mutation. Cleanup does not release its lease or remove candidates. Existing source/model consent, staged checksum/0600, cancellation-after-install uncertainty, explicit clear barrier, partial committed index and lexical/filename fallback remain. All production worker factories were enumerated: service query/index/media defaults and the lazy media factory use these owners; standalone constructors and explicitly injected factories retain their own responsibility.

## Focused validation

78 distinct methods were selected and executed (21 XCTest, 57 Swift Testing), including 10 new lifecycle XCTest and two new UI/service methods. First pass: 74/78. An unchanged four-method retry passed the two existing idle/cancellation methods but the two new fixtures still failed. After waiting for actual async cleanup, 49/50 affected methods passed. The service fixture then proved malformed: its new script omitted required `entries`, correctly faulting the role and entering cooldown. Added the field and required successful warmup before revocation. Final affected pass: **50/50 (20 XCTest, 30 Swift Testing)**. The other 28 initial passing methods were not repeated. All production source hashes are unchanged since the first functional pass.

Failures are retained in the history: the initial lazy-media fixture also reported one Cocoa 513 temporary-directory removal error; it did not recur. Its cause was not established. Two pre-existing idle/cancel timing assertions failed initially and passed both the unchanged isolation retry and final pass; no production timing limit was relaxed, and the initial timing cause is unknown. New fixture busy errors were corrected by waiting for real retirement, not by accepting replacement capacity. No assertion or runtime failure remains in the final scope.

Tests cover independent files/budgets, simulated clock and corrupt reset, pre-DI refusal, known EINVAL/EIO refusal vs malformed promised vectors, EOF/invalid JSON/hang/missing executable, stale cache/queued prepare, blocked host and delayed collection, duplicate adapter and owner release, mutation versus readiness/disable, capability-only recovery, explicit new worker, private native-script service preparation, account/source lifecycle compatibility, retained model on explicit clear and filename/lexical fallback. Existing ownership/artifact/media/worker/service suites exercise their mapped compatibility paths. Native helpers use private scripts/synthetic vectors and placeholder files, not real models.

Actual settings restore buttons for all three domains were pressed from corrupt health state and restored readiness with owners still idle. The 640×370 screenshot was inspected. Five localization tables changed; the existing localization parser test passed initially.

Build command (through `scripts/test_runtime.child_environment`):

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

Final XCTest executable contains `__llvm_covmap` and `__llvm_prf_cnts`. Prebuilt inventory used `native_environment`, `native_tools` and `swiftpm-testing-helper` (no discovery rebuild / xctest-as-program). Initial inventory: 78; final: 50. Execution:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter "$EXPLICIT_SCOPE"
```

Exact initial scope:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticModelModuleTests[./]|SemanticModelHealthViewTests[./]|SemanticEmbeddingOwnershipTests[./]|SemanticEmbeddingServiceOwnershipTests[./]|SemanticArtifactOwnershipTests[./]|SemanticArtifactServiceTests[./]|SemanticEmbeddingWorkerTests[./](?!realModel)|SemanticMediaWorkerTests[./](?!realImage|realMediaFiles)|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticRealtimeSearchTests[./](?!`real file)|SemanticMediaServiceTests[./]|SemanticPreparationServiceTests[./]|SemanticIndexFairnessServiceTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|LocalizationResourceTests[./]testLauncherGeneralAndInputSourceCopyExistsInEveryLanguage)
```

Exact final scope:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticModelModuleTests[./]|SemanticModelHealthViewTests[./]|SemanticEmbeddingOwnershipTests[./]|SemanticEmbeddingServiceOwnershipTests[./]|SemanticArtifactOwnershipTests[./]|SemanticArtifactServiceTests[./]|SemanticEmbeddingWorkerTests[./](?!realModel)|SemanticMediaWorkerTests[./](?!realImage|realMediaFiles)|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticMediaServiceTests[./]|SemanticPreparationServiceTests[./]|SemanticIndexFairnessServiceTests[./]|StorageSemanticIndexFairnessServiceTests[./])
```

Snapshot environments were `TYPEFLUX_ASK_SNAPSHOTS` and `TYPEFLUX_GUL303_SNAPSHOTS`. No full suite. No helper/protocol/entrypoint/packaging change, so no additional copied-bundle/packaging probe. The optional native semantic helper and real weights were not run. No real CoreML, model download/provider/network, user-home/network-mount/TCC scan, capture/mic, audio output, user clipboard/paste/wheel, external apps, full Xcode, signing or hardware validation.

## Evidence and timings

Changed executable lines: **133/135 = 98.52%** against the actual base. Ownership 48/48, worker 18/18, service 11/11, lazy media 6/6, adapter 50/50. Only DI composition lines 171–172 are unhit. Definition/guard hits do not prove both branches, all errno paths, native allocation, device/model behavior, watchdogs or real quit.

ONLY three fresh final HOST profiles from ONE final binary were individually validated with `llvm-profdata show`, merged warning-free, and read with matching app `llvm-cov --object`. New Sources were included with `git add -N`. No child coverage claim: persistent children collected after termination need not emit LLVM profiles. Initial three + unchanged retry three + fixture-correction three profiles are archived separately and EXCLUDED; no cross-layout merge (Swift hashes are zero). Root inventory/launcher `default.profraw` is excluded. Final local evidence is `.build/semantic-model-health-validation/final`; binary hashes:

- XCTest: `784aa022bd5eac3e8998200ffc3c10ebc8419442871124c154590cfd98eae4ab`
- App: `2db359c1206a7334b05ece53dee93ffebb06ca617254327978538c0a1eaea99b`

All source hashes match the first functional pass and final evidence ledger. No Sources/tests changed after the last build. App minOS is 13.0; existing XCTest runtime is 14, not macOS 13 Intel hardware proof.

Build wall seconds: 47.05 failed (new nonescaping cancellation closure); 196.58 passed with a new local Sendable warning; 61.04 passed after fixing the warning and pre-test additions; 60.75 passed for fixture retirement waits; 54.99 passed for the fixture protocol correction. No functional tests ran before build three. Test wall seconds: 68.23 initial; 2.36 unchanged isolation retry; 21.84 fixture correction; 26.25 final. Inventory 4.008 + 4.047. Total tracked commands **547.145 s**, excluding archive/extraction/audit/image inspection and startup overhead outside these runners.

## Remaining boundaries

These are per-service DEFAULT native owners, not global model-path leases across processes, services or custom factories. Read-only verify/FS and external aliases are not immutable transactions. Uncooperative FS/consumer work retains capacity; there is no whole-app quit deadline, rollback, aggregate memory/disk or power-loss guarantee. Already-entered callbacks/dispatched writes may have effects. Existing installation candidate/receipt limitations are unchanged; health never deletes/recreates databases/models or retries installation.

Progress/download/current-path callbacks still create MainActor tasks per update; bounded progress delivery remains a separate increment. Broader feature/condition lifecycle and native/media audit remain, as do audio/TCC/signing/performance before microphone ownership decisions, real CoreML/model performance, full Xcode/Developer ID/notarization/macOS 13 Intel/actual quit recording. Capture/live meter and OS QuickLook remain separate boundaries. Overall GUL-399 remains in_progress.
