# GUL-399: clipboard metadata lifecycle and persistent health

Base: open draft #564, `bc1e930a38492b255d4d1ef8ef59a11f6ea3aa30`, branch `agent/arch-gpt-astra/gul-399-clipboard-ocr-health`. #564 depends on #563/#562/#561, all still open at initial audit. Earlier work through #560 is on main. Main at audit is `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`; its storage-only quarantine auto-recovery, persistent chat feedback and background-task window changes are not in this feature tree. Read-only merge-tree is clean; no merge performed. Preserve those changes and storage's exclusive automatic persistent-reset opt-in on later integration.

## Behavior and caller audit

`MediaWorker.clipboardMetadata` now requires lifecycle readiness and has independent `ModuleID.clipboardMetadata` / `clipboardMetadata.json`. The existing closed domain mapping/composition retains seven independent media adapters alongside the unchanged three stores. Five localized health labels expose the existing settings recovery control. No new pool, executable, helper protocol, DI logic or global test bypass.

Reservations remain once per factory generation, never per PDF/duration/waveform request. Expected source/configuration/input refusals remain distinct from process/protocol failures, including #564's corrected invalid-success-envelope classification. Persistence is bounded, content-free and off UI; corrupt records remain until explicit reset. Readiness checks helper executable availability, not native formats or signing. Cleanup does not replace an occupied pool: both host completion and actual child retirement remain necessary before capacity reopens.

Audited ClipboardMediaInfoProvider, ClipboardMediaProjection/ClipboardMediaValue, panel row, preview pane, waveform/inline media and session/controller account, selection, entry replacement/deletion, actual hide and collapse paths; DI construction/quit and all direct provider tests. Existing provider worker and projection read-closure seams suffice. Four standalone default-provider fixtures now inject explicit workers without full DI. Composition verifies seven exact ID/worker mappings. Production pre-DI requests fail closed.

The same two preparation admissions, two-child/10-second domain, 35-second child alarm and typed contracts remain: PDF input 50,000,000 bytes/page count at most one million; AV input 512 MiB; finite bounded duration; first 600 seconds, mono 8 kHz, 180 normalized peak buckets, 4 MiB PCM chunks and 24 MiB aggregate. This is not recording timeline's whole-recording 160-bucket contract or Ask preview's 30-second/80-bucket contract. Original sources and copy/paste/capture/playback behavior remain unchanged.

Projection keeps the attempted request identity after failure, so readiness or body recomputation cannot reread an old request. Original account/source/epoch/session authority still governs publication; fresh permission cannot bless late results. Actual panel hide/account/deletion/owner release clears outputs. Capture pause still permits history viewing. Missing metadata preserves existing approximate details and waveform placeholder, never fabricated zero page counts/durations. No auto capture, clipboard read, copy/paste, producer or workflow replay.

Host file revision inspection precedes worker admission, bounded by two preparation slots. Filesystem calls can be uncooperative; snapshots are not immutable transactions. Health readiness is not a grant of source access.

## Validation

**74/74 distinct focused methods passed in one pass**: 54 XCTest and 20 Swift Testing. No compilation failures, functional failures or correction retries. No full suite.

| Scope | Methods | Evidence |
| --- | ---: | --- |
| ClipboardMetadataModuleTests | 7 | pre-DI unavailable; independent OCR/metadata budgets; corruption/clock/reset; source/typed refusals vs invalid metadata; cancellation retaining reaped-child/uncooperative-host slots; real managed PDF/duration/waveform and no readiness retry; actual panel hide/account/deletion/owner release rejects late output and fresh permission |
| ClipboardMetadataHealthViewTests | 1 | actual health row/AX recovery button without reading files; screenshot inspected |
| ClipboardMetadataIsolationTests | 12 | protocol/PCM bounds, real native files and 600-second window, source mutation, crash/hang, cancellation, request identity, scoped UI and privacy |
| ClipboardMediaInfoProviderTests | 8 | changed standalone injections, PDF/duration/waveform, cancellation/fallback and peak arithmetic |
| ClipboardRowRenderingTests | 4 | row sizing/equality, media and waveform fallback rendering |
| ClipboardPreviewPaneTests | 4 | details, each content kind, preview panel and controller resizing |
| ClipboardThumbnailIsolationTests | 2 | shared actual hide/close/account, capture pause/collapse/owner lifetime |
| MediaExtractionModuleTests | 13 | reused readiness, fault generations, persistence, conditions, retirement and quit |
| ModuleRegistryTests | 12 | dependency lifecycle and old-work fencing |
| ModuleHealthStoreTests | 6 | persistence bounds/corruption/quarantine/clock/reset |
| StorageModuleRegistryTests | 1 | unchanged storage composition |
| MediaWorkerTests | 2 | retained child capacity and shutdown |
| ClipboardThumbnailModuleTests | 1 | seven exact production domain mappings |
| LocalizationResourceTests | 1 | all five string tables parse |

Commands use `scripts/test_runtime.child_environment`:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <regex below>
python3 -m unittest scripts.tests.test_media_packaging
```

```text
^Typeflux(?:Focused)?Tests[./](?:ClipboardMetadataModuleTests[./]|ClipboardMetadataHealthViewTests[./]|ClipboardMetadataIsolationTests[./]|ClipboardMediaInfoProviderTests[./]|ClipboardRowRenderingTests[./]|ClipboardPreviewPaneTests[./](?:testDetailRowsDescribeTheEntry|testPaneDrawsEveryKind|testPanelRendersWithThePreviewPane|testControllerWidensThePanelForThePreview)(?:\(|$)|ClipboardThumbnailIsolationTests[./](?:testActualOrderOutCloseAndAccountChangeRevokePanelScope|testPausePreservesHistoryButHiddenPreviewAndOwnerReleaseClearPixels)(?:\(|$)|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./](?:testTwoRetainedChildrenBoundAdmissionAndShutdownFences|testShutdownCancelsRunningChildAndRejectsNewWork)(?:\(|$)|ClipboardThumbnailModuleTests[./]testProductionCompositionMapsEveryIndependentPoolWithoutStartingRequests(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))
```

Prebuilt inventory used native_environment/native_tools + swiftpm-testing-helper, not direct xctest execution or a discovery rebuild. Both snapshot environment variables were enabled. No source/test inputs changed after the final build.

- Build **110.37 s** (inner 106.73 s), passed.
- Inventory **4.639 s**, matched 74 methods.
- Focused command **34.24 s** (54 XCTest 11.487 s; 20 Swift Testing 0.409 s), passed.
- **2/2 packaging checks passed**, unittest reported **0.149 s**. No copied-helper probe because helper/protocol/packaging are unchanged; real managed synthetic PDF/WAV and existing crash/hang fixtures ran.
- Tracked total **149.398 s**, excluding packaging interpreter startup, audit, archival/extraction and screenshot inspection. Existing unrelated compiler warnings remain.

Actual 640×190 `clipboard-metadata-health.png` inspected: localized service title, unavailable status, recovery button and no-replay explanation visible. No real clipboard/copy/paste/wheel, screen/microphone capture/TCC, audio output, network/provider/external app, full Xcode, signing or hardware exercise. Synthetic audio was analyzed, never played. All jobs/children collected.

## Coverage attribution and limits

Against actual PR base `bc1e930a`, **2/2 added executable lines = 100%**. This tiny denominator is exactly the new ID/worker mapping branches. Enum/static declarations have no added line counters; this is not whole-feature, branch, native allocation, watchdog/device or actual app-quit proof.

Coverage uses **17 fresh profiles** (3 host, 14 direct helper) from ONE final binary. Every raw profile individually validated; warning-free merge; helper included as llvm-cov `--object`; LLVM covmap/counter sections verified. No old passing results/profiles or cross-layout merges. Inventory-only default.profraw archived separately and excluded. Production hashes verified unchanged. Local evidence `.build/metadata-health-validation/final`.

- XCTest SHA-256: `a78f77c090ce0e8988c5cba5eecb1057e5d6e2c821f226cebf45114abb09be82`
- Unchanged helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`
- App/helper minimum OS 13.0 is not macOS13/Intel hardware proof.

Remaining domains include recording timeline/encoding, native/inference/playback and feature adapters plus broader condition-driven lifecycle. Custom owned encoding streams/unknown outputs need a separate audit, not blind binding. Preserve retained candidates/receipts and single authorized publication; no writes/toggles/Agent/workflow/system-command/paid-generation/shutdown replay or database deletion/recreation.

Remaining native/media audit and audio/TCC/signing/performance validation precede microphone capture ownership decisions. File analysis does not decide capture. Live capture/audio meter, host filesystem/raw raster/JSON/base64/pasteboard/SQLite/import-export/UI and AppKit/GPU/system memory remain boundaries. User-requested OS Quick Look is an OS/UI boundary; existing file/semantic workers are not duplicated. Real CoreML/full Xcode/Developer ID/notarization/macOS13/Intel/actual quit-recording remain unverified. No arbitrary host crash, system-wide OOM or power-loss guarantee. GUL-399 remains in_progress.
