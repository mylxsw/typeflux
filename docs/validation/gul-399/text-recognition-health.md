# GUL-399: shared text recognition lifecycle and persistent health

Base: open draft #562, `777441e9b339e9758a36a990618dfdcd3bb3790f`, branch `agent/arch-gpt-astra/gul-399-registration-health`. #562 depends on open #561. This is a stacked increment, not a main integration. Earlier work through #560 is on main. At audit main was `884df81fabf08f79f4643c85cd3521cf241abf21`, with storage-only one-shot quarantine recovery and persistent chat storage feedback changes not present in this tested feature tree. Read-only merge-tree succeeded. Parent PR bases are preserved; no PR merge or CI wait.

## Behavior and caller audit

`MediaWorker.textRecognition` now requires lifecycle binding/readiness. The existing closed `MediaExtractionModule.Domain` mapping adds independent `ModuleID.textRecognition` / `textRecognition.json`. Existing `MediaExtractionModules` retains five media adapters alongside the unchanged three storage modules. Five localized settings labels expose the existing health/recovery UI. No new helper, protocol, pool, executable, full-DI test initialization or mutable test bypass.

Persistent reservations remain once per factory generation, not per OCR request, band or mosaic. Content-free bounded persistence, explicit corruption reset, coalesced observation, generation fencing and fault classification reuse the existing adapter. Input/source/typed refusal does not mark the domain crashed; invalid child responses and process failures do. Readiness checks executable availability, not native language/format/signing readiness. Recovery only restores capability; there is no saved image/request to replay, translate, redact, copy or export.

Audited `VisionImageTextRecognizer` URL/raw-image paths and shared `recognizeText`/`textGeometry` transport; `TiledImageTextRecognizer`; `VisionTextHeightMeasurer`; mosaic preparation/overlay/long-image ownership; `VisionSensitiveInfoScanner`/redaction controller; launcher screenshot recognition and translation panel; DI production factories and all direct native default tests. The recognizer/measurer already offer explicit injection. Three old fixture files now inject standalone workers, and the composition test verifies five exact worker/ID mappings. Production pre-DI calls fail closed.

Exact UTF16 sensitive-range boxes and pure synchronous RangeLocator lookup are unchanged. No proportional geometry or host Vision objects are introduced. Confidence, reading order, orientation/top-left mapping, overlapping-band merge and bounds, conservative whole-mask pending/failure behavior and export freeze are unchanged. Recognition failures remain errors, not empty text or zero-risk success. Existing source/session/account/window/selection/cancellation ownership continues to reject late output. The new managed redaction test proves readiness cannot turn a failed scan into success or revive an account-retired panel.

The same two preparation admissions and two-child/30-second text pool retain actual child collection AND host completion before capacity reopens. Child alarm remains 35 seconds. Encoded input stays 10 MiB; raw input 16384-axis/16-million-pixel/64 MiB; response 2 MiB with bounded lines/UTF16 geometry. Tiling keeps its separate overall/band/aggregate limits. Host raw rasterization and file revision inspection still precede worker lifecycle admission, bounded by preparation slots; no claim that a closed lifecycle gate eliminates all host work. Cleanup timeout cannot replace an occupied pool. Feature scopes remain the privacy authority; lifecycle readiness is not fresh source permission.

Clipboard file-to-text OCR remains a different, currently unmanaged pool. Storage's newer main-only automatic persistent reset opt-in must not be accidentally applied to media on later integration.

## Validation

**81 distinct focused methods passed across an initial 80/81 pass and a one-method correction retry (1/1)**: 61 XCTest + 20 Swift Testing. Initial failure: the new 900×240 synthetic text fixture returned `a@example.con`, not the expected `a@example.com`. Widened only that test fixture to 1400×240, matching the existing native exact-box fixture. Production sources did not change after the first build; hashes verified. No build failure. No full-suite run.

| Scope | Methods | Evidence |
| --- | ---: | --- |
| TextRecognitionModuleTests | 7 | pre-DI error vs empty; independent budgets; corruption/clock/reset; typed refusal vs malformed text; cancelled uncooperative host and late valid result; managed real raw/file OCR + exact ranges + geometry; failed/account-retired redaction not revived |
| TextRecognitionHealthViewTests | 1 | real health row and AX recovery button without recognition; inspected screenshot |
| SharedOCRIsolationTests | 10 | exact Unicode/tile regions, native boxes, protocol bounds, file mutation, cancellation, translation hide/account, launcher replacement and redaction failure |
| MosaicGeometryIsolationTests | 11 | geometry bounds/scale, native detector, identity/undo/redo, safe failure/export, account/hide/owner and late results |
| ImageTextRecognizerTests | 7 | changed native fixtures, file/raw/blank/failure/top-left/pure locator |
| ImageTilingTests | 6 | overlap/exact geometry, bounded tiled delegation and cancellation |
| ScreenshotRendererTests | 2 | changed native height fixtures |
| ScreenshotCalloutMosaicTests | 1 | changed native no-text geometry fixture and options |
| MediaExtractionModuleTests | 13 | reused lifecycle/generation/conditions/retirement/quit |
| ModuleRegistryTests | 12 | dependency ordering and bounded old work |
| ModuleHealthStoreTests | 6 | bounded persistence, corruption/quarantine, clock/reset |
| StorageModuleRegistryTests | 1 | unchanged storage composition |
| MediaWorkerTests | 2 | retained child admission/shutdown |
| ClipboardThumbnailModuleTests | 1 | changed five-domain composition |
| LocalizationResourceTests | 1 | all five string tables parse |

Commands use `scripts/test_runtime.child_environment`:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <regex below>
python3 -m unittest scripts.tests.test_media_packaging
```

```text
^Typeflux(?:Focused)?Tests[./](?:TextRecognitionModuleTests[./]|TextRecognitionHealthViewTests[./]|SharedOCRIsolationTests[./]|MosaicGeometryIsolationTests[./]|ImageTextRecognizerTests[./]|ImageTilingTests[./](?:testOneBandKeepsVisionsOrderAndPlacesLinesOnTheImage|testLinesInTheOverlapAreKeptOnceAndPlacedOnTheWholeImage|testExactBoundsFollowTheLineOntoTheWholeImage|testTheTiledRecognizerReadsLongImagesBandByBand|testTheTiledRecognizerPassesShortImagesAndFilesThrough|testTheTiledRecognizerStopsWhenCancelled)(?:\(|$)|ScreenshotRendererTests[./](?:testTallestTextLine|testVisionFindsTheHeightOfRealText)(?:\(|$)|ScreenshotCalloutMosaicTests[./]testCalloutAndScopeOptionsRenderAndRoundTrip(?:\(|$)|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./](?:testTwoRetainedChildrenBoundAdmissionAndShutdownFences|testShutdownCancelsRunningChildAndRejectsNewWork)(?:\(|$)|ClipboardThumbnailModuleTests[./]testProductionCompositionMapsEveryIndependentPoolWithoutStartingRequests(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))
```

Retry only `TextRecognitionModuleTests/testManagedNativeTextGeometryAndTiledConsumersPreserveExactBounds` with the same build/skip-build/coverage flags. Prebuilt inventory used native_environment/native_tools + swiftpm-testing-helper; no discovery rebuild or direct xctest invocation.

- Builds **149.36 s** and **40.17 s**, both passed (inner 145.73/39.82 s). Second changes only test image width.
- Inventory **4.246 s**, 81 matched methods.
- Initial focused command **37.39 s** (61 XCTest: 13.556 s; 20 Swift Testing: 0.474 s). One-method retry **10.21 s**, passed.
- **2/2 packaging checks passed**, unittest reported **0.190 s**. No new copied-helper probe because helper/protocol/packaging are unchanged; managed real synthetic OCR/geometry and injected process-fault fixtures ran.
- Tracked total **241.566 s**, excluding packaging interpreter startup, audit, archival/extraction and screenshot inspection. Existing unrelated compiler warnings remain.

Actual 640×190 `text-recognition-health.png` inspected: unavailable label, localized service title, recovery button and no-replay explanation visible. Both snapshot environment variables were enabled. No real capture/TCC, user clipboard/paste/wheel, audio output, network/provider/external app, full Xcode, signing or hardware exercise. All jobs and children collected.

## Coverage attribution and limits

Against the actual PR base, **2/2 added executable lines = 100%**. The tiny denominator is exactly the new domain ID/worker mapping branches; enum/static declarations have no added counters. This is not whole-feature, branch, native allocation, real quit, language/device or watchdog proof.

Coverage uses ONLY the initial production-final binary with **12 fresh profiles** (3 host, 9 direct helper). Every raw profile individually checked; warning-free merge; helper included as llvm-cov `--object`; LLVM covmap/counters verified. The test-only retry has **6 separately validated profiles** (3 host, 3 helper), archived with its matching binary but NOT merged into initial coverage. Production source hashes match across the test-only rebuild. No earlier increment profile/result/layout reused. Inventory default.profraw is separately archived/excluded.

Local evidence `.build/text-health-validation/{initial,final}`:

- Initial XCTest SHA-256: `8656b8fc28161619947419fdbf02d56eca9ea360ae9984508433bc06d96a31e3`
- Retry XCTest SHA-256: `a11e40f946ada5a031ab277758a6dabb6fb0d7aa322ef7c989074b18d6970a6e`
- Unchanged helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`

Remaining domains: clipboard OCR, metadata/timeline/encoding; native/inference/playback and feature adapters; broader condition-driven lifecycle. Custom owned encoding progress and retained unknown outputs are not automatically covered by `perform` fault classification. Preserve candidates/receipts and the single authorized publication; no producer/write/workflow/paid-generation/shutdown replay. User databases are unchanged.

Remaining native/media audit and audio/TCC/signing/performance verification precede microphone capture ownership decisions. File processing does not decide capture. Live capture/audio meter, host filesystem/raw raster/JSON/base64/pasteboard/SQLite/import-export/UI and AppKit/GPU/system memory remain boundaries. Explicit OS Quick Look is an OS/UI boundary; existing file/semantic decoder workers are not duplicated. No arbitrary host crash, system-wide OOM or power-loss guarantee. Real CoreML/full Xcode/Developer ID/notarization/macOS13/Intel/actual quit-recording remain unverified. GUL-399 remains in_progress.
