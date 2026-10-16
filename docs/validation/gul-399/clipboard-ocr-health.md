# GUL-399: clipboard OCR lifecycle and persistent health

Base: open draft #563, `2d6c70fb23539e5c7c16d76a146418bb73b1fa47`, branch `agent/arch-gpt-astra/gul-399-text-health`. #563 depends on open #562 and #561. This increment is stacked, not a main integration. Earlier work through #560 is on main. At audit main was `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`, with storage-only quarantine auto-recovery, persistent chat feedback and background-task window changes absent from this feature tree. Read-only merge-tree succeeded; no merge performed. Preserve those changes on later integration, and do not opt media into storage's automatic persistent-budget reset. Existing PR bases remain unchanged.

## Behavior and caller audit

`MediaWorker.clipboardOCR` now requires lifecycle binding/readiness. The existing closed `MediaExtractionModule.Domain` maps independent `ModuleID.clipboardOCR` / `clipboardOCR.json`. Existing composition retains six independent media adapters alongside the unchanged three stores. Five localized labels expose the existing health/recovery UI. No new helper, protocol, pool, executable or full-DI test initialization.

The same two host preparation admissions, two-child/30-second OCR pool, 35-second helper alarm and private input copies remain. Occupied slots stay held through actual child collection AND host completion; cleanup timeout cannot replace an occupied pool. Health reservations are once per factory generation, never per OCR request. Persistence stays bounded/content-free/off UI, with corrupt bytes preserved until explicit reset. Readiness checks executable availability, not native format/language/signing readiness. Original feature authority is still required independently of lifecycle readiness.

Audited `ClipboardTextRecognizer`, SystemClipboardContentActions, ClipboardContentAction.startText, WorkflowController+History.copyHistoryImageText, DI/AppCoordinator construction/quit and all direct default tests. Added an explicit `textWorker` parameter to SystemClipboardContentActions for standalone tests. Production defaults stay `.clipboardOCR`; the optional shared ImageTextRecognizing injection remains only the existing test seam, not a production fallback. Pre-DI use fails closed. The composition test verifies six exact worker/ID mappings.

File-to-text bounds remain 10 MiB input, 16384-axis/16-million-pixel image, 2 MiB response with bounded lines and text. Shared screenshot/geometry OCR remains a separate domain. Host file revision inspection still precedes worker health admission and can block within the two preparation slots; metadata checks are not immutable filesystem transactions.

The explicit copy owner still rejects duplicate actions, retains cancelled uncooperative work, and checks original source revision/account/generation/history membership/selection/panel visibility before one commit. Empty recognition differs from unavailable/error. Recovery only restores capability: it cannot recognize old input, reread live clipboard, copy/paste, capture, translate or replay a workflow. Tests verify fresh permission cannot authorize an old pending result, and account revocation prevents a late commit. Private pasteboard fixtures remain unchanged by recognition; actual history copy tests use injected sinks.

## Fault-classification correction

The initial new malformed-output test exposed a real shared classification gap. MediaOCRResult rejects NUL/oversized text using `tooLarge`; a child success envelope with such invalid text was rejected but did not mark managed health failed. MediaWorker now marks validation failure of a **success envelope** as an infrastructure/protocol fault regardless of the validator's error code. Explicit, structurally valid child `unreadable` / `tooLarge` refusals remain expected input failures. Identity, JSON and mixed-payload faults retain existing handling. No failed request is retried. This correction applies to managed `perform` consumers; custom `owned` encoding streams are not thereby integrated or classified.

## Validation

Final **65/65 distinct methods passed**: 45 XCTest and 20 Swift Testing. The first 58-method scope passed 57/58, with the malformed success-payload health test failing. After the production correction and an explicit typed-tooLarge assertion, the final scope includes all nine MediaWorker tests (seven more than initially) and reruns affected lifecycle/caller compatibility. No compilation failures. No full suite.

| Scope | Methods | Evidence |
| --- | ---: | --- |
| ClipboardOCRModuleTests | 7 | pre-DI refusal; independent shared-text/clipboard budgets; corruption and simulated clock; typed refusals vs invalid success; cancellation retaining host capacity; managed native OCR/blank/malformed and explicit single commit; late account/permission result rejected |
| ClipboardOCRHealthViewTests | 1 | actual health row and AX recover button without OCR/copy; screenshot inspected |
| ClipboardOCRIsolationTests | 8 | protocol/input limits, real file OCR, source mutation, cancellation, explicit copy/deletion/hide/owner/duplicate handling |
| SystemClipboardContentActionsTests | 2 | changed worker injection, real OCR and private PNG/TIFF copy compatibility |
| SystemClipboardContentActionsRecognizerTests | 2 | optional recognizer injection and error distinct from empty |
| WorkflowControllerProcessingTests | 2 | real history controller with injected clipboard sink; explicit success/failure/deletion |
| MediaExtractionModuleTests | 13 | reused lifecycle, persistence, fault generations, conditions, sibling retirement and quit |
| MediaWorkerTests | 9 | all shared transport/copy/ownership/protocol/cancellation/shutdown/crash/hang tests |
| ModuleRegistryTests | 12 | dependency lifecycle and old-work fencing |
| ModuleHealthStoreTests | 6 | persistence bounds/corruption/quarantine/clock/reset |
| StorageModuleRegistryTests | 1 | unchanged storage composition |
| ClipboardThumbnailModuleTests | 1 | six exact production domain mappings with injected workers |
| LocalizationResourceTests | 1 | five string tables parse |

Commands use `scripts/test_runtime.child_environment`:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <regex below>
python3 -m unittest scripts.tests.test_media_packaging
```

```text
^Typeflux(?:Focused)?Tests[./](?:ClipboardOCRModuleTests[./]|ClipboardOCRHealthViewTests[./]|ClipboardOCRIsolationTests[./]|SystemClipboardContentActionsTests[./](?:testRecognizesTextInImages|testWritesStoredImagesAsPNGAndTIFF)(?:\(|$)|SystemClipboardContentActionsRecognizerTests[./]|WorkflowControllerProcessingTests[./](?:testCopyImageTextCopiesRecognizedText|testHistoryOCRFailureAndDeletionNeverWrite)(?:\(|$)|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./]|ClipboardThumbnailModuleTests[./]testProductionCompositionMapsEveryIndependentPoolWithoutStartingRequests(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))
```

Prebuilt inventory used native_environment/native_tools + swiftpm-testing-helper, with no discovery rebuild or direct xctest execution. Initial regex differs only by selecting two ownership/shutdown MediaWorker methods instead of all nine. Both snapshot environment variables were enabled. No source/test input changed after the final build.

- Builds **134.20 s / 67.32 s**, both passed (inner 131.33 / 66.85 s).
- Inventories **4.824 s / 3.782 s**, matching 58 / 65 methods.
- Initial focused command **42.02 s**, one failure; final **11.97 s**, all passed (45 XCTest 5.782 s, 20 Swift Testing 0.423 s).
- **2/2 packaging checks passed**, unittest reported **0.139 s**. No copied-helper probe because helper/protocol/packaging are unchanged. Managed real private OCR and existing process fault fixtures executed.
- Tracked total **264.255 s**, excluding packaging interpreter startup, audit, archival/extraction and screenshot inspection. Existing unrelated compiler warnings remain. One log-read command used repository cwd instead of workspace cwd; corrected the read without rerunning tests.

Actual 640×190 `clipboard-ocr-health.png` inspected after the final pass: localized title, unavailable state, recovery button and no-replay explanation visible. No real user clipboard, paste/wheel, capture/TCC, audio output, network/provider/external app, full Xcode, signing or hardware exercise. All jobs/children collected.

## Coverage attribution and limits

Against the actual PR base, **11/11 added executable lines = 100%**: seven shared worker response-validation lines, two SystemClipboardContentActions injection/forwarding lines, two domain ID/worker branches. Enum/static declarations have no added counters. This small denominator does not prove all branches, native allocations, device/language/watchdog behavior or real application quit.

Coverage uses ONLY **14 fresh profiles** from the final binary (3 host, 11 direct helper). Every raw profile individually validated; warning-free merge; helper included as llvm-cov `--object`; LLVM covmap/counter sections verified. Initial 11 profiles are archived separately and excluded after the production correction. No earlier increment results/profiles or counter layouts reused. Production hashes verified unchanged after the final build. Local evidence `.build/clipboard-ocr-health-validation/{initial,final}`.

- Final XCTest SHA-256: `6bc4f222bc705bf961ceb8e4dfce8dc6d80ce27b2dfac1761dc7bdae8bbe7f06`
- Unchanged helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`
- App/helper minimum OS: 13.0; this is not macOS13/Intel hardware proof.

Remaining domains: clipboard metadata, recording timeline/encoding, native/inference/playback and feature adapters; broader condition-driven lifecycle. Custom encoding progress/unknown-output retention needs its own adapter audit. Candidates/receipts and single authorized publication remain intact; no producer/write/workflow/paid-generation/shutdown replay, database deletion or recreation.

Remaining native/media audit and audio/TCC/signing/performance verification precede microphone capture ownership decisions. File processing does not decide capture. Live capture/audio meter, host filesystem/raw raster/JSON/base64/pasteboard/SQLite/import-export/UI and AppKit/GPU/system memory remain boundaries. Explicit OS Quick Look is an OS/UI boundary; existing file/semantic decoder workers are not duplicated. No arbitrary host crash, system-wide OOM or power-loss guarantee. Real CoreML/full Xcode/Developer ID/notarization/macOS13/Intel/actual quit-recording remain unverified. GUL-399 remains in_progress.
