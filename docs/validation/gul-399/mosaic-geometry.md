# GUL-399: asynchronous mosaic text geometry

The production `VNDetectTextRectanglesRequest` and `VNImageRequestHandler` now execute only in the existing media helper. `ScreenshotTextHeightMeasuring.geometry` is async and throwing. Both the region overlay and long-image canvas prepare only the crop under a completed mosaic, using the frozen image. The pure editor's legacy injectable closures remain for value-level tests; production views do not call native work through them.

## Contract and ownership

- New allowlisted `textGeometry` operation requires explicit raw RGBA dimensions. It reuses the existing raw text transport, private input copies, two host admissions before detached serialization, two-child/30-second text-recognition pool, 35-second helper alarm and confirmed-reaping leases. It shares this bounded Vision domain with shared OCR, not inference or a global worker. No new target, DI service, signing asset or packaging path.
- Maximum 16,384 per axis, 16,000,000 pixels, 64 MiB raw frame; 1 KiB request and 2 MiB response transport. Maximum 1,024 rectangles, all finite, positive and normalized within the image. Requests and responses validate operation/version/UUID and reject mixed payloads. No recognized text, Vision object or synchronous IPC crosses the interface.
- Finite crop/bounds checks precede integer conversion. Cropping, RGBA serialization and bitmap display remain host boundaries. Exact crop offsets and independent x/y point scales are preserved; oversized long-image crops fail without downscaling or scanning the whole image.
- One owned preparation per editor, with no queue and no replacement while cancelled work is uncooperative. Refresh/drawing does not resubmit an attempted request. A new explicit gesture/scope action may request a new preparation; no recapture, workflow, Agent, clipboard or producer replay.
- Pending/failed masks cover the whole original shape with conservative height-based block sizing. Successful empty detection also keeps the whole shape, using the existing no-text sizing. Valid text-scope results use the original shape-center filtering and line heights. Five-language notices distinguish pending/unavailable detection from success.
- Completion requires the original operation generation, document snapshot, selection, crop and annotation ID. Equal shapes cannot identify annotations. Completion joins the original gesture without adding an undo step; undo/redo preserve the completed value. A document/selection change cancels the attempt. Save/copy/pin handoff freezes the current annotations and revokes pending completion; it never waits on a decoder to produce a protected export.
- Account/token events, owner release and actual panel `orderOut`/close retire preparation. Inputs remain retained through asynchronous completion and worker-owned copies through confirmed retirement. Original screenshot annotations/bytes are not deleted on detection failure. Returning to a retired owner does not silently start old work.

## Validation

Implementation and self-review preceded the focused functional pass. No full suite or discovery rebuild was run. Direct build:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

Both the XCTest binary and media helper were checked for `__llvm_covmap` and `__llvm_prf_cnts`, then:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:MosaicGeometryIsolationTests[./]|ScreenshotRendererTests[./](?:testTallestTextLine|testVisionFindsTheHeightOfRealText)|ScreenshotEditorOverlayTests[./](?:testMosaicsAreSizedToTheTextUnderThem|testWithoutAToolTheRegionStillMovesAndDoubleClickCopiesWithTheMarks|testControllerHandsOverAnnotationsInGlobalPoints)|ScreenshotLongImageEditorTests[./](?:testMosaicsAreSizedToTheTextUnderThem|testPresentingAgainReplacesTheEditor)|ScreenshotCalloutMosaicTests[./](?:testTheTextScopeCoversOnlyTheLinesFoundInsideTheShape|testTheTextScopeFallsBackToTheWholeShapeAndSkipsBrushes|testTheOverlayFindsTextLinesInTheFrozenImage|testCalloutAndScopeOptionsRenderAndRoundTrip)|ScreenshotAnnotationEditorTests[./](?:testMosaicBoxAndBrushUseTheChosenOptionsAndMeasureText|testChangingMosaicOptionsChangesTheSelectedMosaic)|SharedOCRIsolationTests[./](?:testProtocolRejectsBoundsUTF16OverlapAndMixedResponses|testChildReadsRawOrEncodedInputAndRejectsTruncationBeforeEngine|testRealHelperKeepsSensitiveGlyphBoxesAndRawImageOrientation|testUncooperativeCancellationRetainsTwoAdmissionsAndShutdownRefusesMore|testSourceMutationAndOversizeNeverReturnPreparedText)|MediaWorkerTests[./](?:testRealHelperImagePDFMalformedAndCrashHangFixtures|testShutdownCancelsRunningChildAndRejectsNewWork)|MediaProtocolTests[./](?:testInvalidIdentityVersionAndAmbiguousResponsesFailClosed|testCommandFramesReadFailureAndSuccessfulResponse))'
```

The command used `scripts/test_runtime.child_environment()` through the task-local runner. **33/33 distinct XCTest methods passed in one functional pass**, with no failed tests or functional retries. Scope mapping:

- 11 new `MosaicGeometryIsolationTests`: protocol identity/mixed payload/bounds, malformed raw input before the injected engine, real helper blank/text detection, cropped/scaled coordinates and nonfinite geometry, stable annotation identity, safe pending export, single-step undo/redo, empty result, failed/no-retry behavior, uncooperative cancellation/admission, account/export fences, actual panel hide/release and rendered pending/failure notices.
- 2 renderer detector methods and 3 overlay/2 long-image methods: native result sizing, cropped pixel dimensions, export, double-click copy and actual controller lifetimes.
- 4 callout/mosaic and 2 pure editor methods: text-scope fallback, geometry, unchanged brush/style semantics and toolbar localization rendering.
- 5 shared OCR methods: compatible raw/encoded transport, exact glyph geometry, input mutation, bounds and retained cancellation admissions.
- 2 worker and 2 protocol methods: harmless real child crash/hang/shutdown and existing image/PDF framing compatibility.

Two packaging tests (`python3 -m unittest scripts.tests.test_media_packaging`) passed. A helper installed into a private synthetic `.app/Contents/Helpers` by the real packaging script accepted a private 200×200 raw-white frame, returned an empty geometry array with matching identity, and preserved the input bytes. No original-image host parser fallback exists. `nm -u Typeflux` contains no `VNDetectTextRectanglesRequest` reference. App/helper deployment target remains macOS 13; this is not macOS 13/Intel hardware validation.

`mosaic-geometry.png` is the actual toolbar component fixture, showing pending and unavailable states; it was visually inspected. It is not a screenshot of live screen capture. Tests used synthetic images, private files, injected recognition and export callbacks; no user clipboard write, paste event, real capture, network, paid provider or TCC action.

| Command | Wall time | Outcome |
| --- | ---: | --- |
| Preparation build 1 | 225.66 s | Failed: new test wait helper needed an escaping predicate declaration |
| Preparation build 2 | 56.06 s | Passed |
| Preparation build 3 | 44.04 s | Failed: new malformed-coordinate fixture needed explicit `CGFloat.infinity` |
| Final build | 74.69 s | Passed |
| One focused test command | 21.96 s | 33/33 passed; XCTest execution 8.925 s |
| Packaging command | 0.363 s | 2/2 passed |
| Copied-helper probe | 0.215 s | Passed |
| Tracked total | 422.988 s | Audit, archival, extraction and visual inspection additional |

Compiler fixture corrections and the final ownership/bounds review occurred before any test execution. Existing unrelated concurrency/deprecation warnings remain; no new production warning was introduced.

## Coverage attribution

**208/210 changed executable lines = 99.05%**, detailed in `mosaic-geometry-coverage.json`. New source files were included with `git add -N` before extraction. Only 11 fresh profiles from the one final binary set were used: 3 host, 7 direct-helper and 1 copied-helper. Every raw profile was individually checked with `llvm-profdata show`; the sparse merge completed without warnings. No old increment profiles, failed-build results, or changed counter layouts were merged. The helper was supplied as `llvm-cov --object` so child-only changed lines were counted.

Matching evidence is archived locally in `.build/mosaic-validation/final` (not a delivered runtime path). SHA-256:

- XCTest: `ff6e1a53b564b5ee63742126a7d2b4535707a56e3ad1bfe273a040f8a76488af`
- Helper: `86487dc6b1da7ed008466d0e08d294dcd98b238033acdad77f002f1509778bac`

Uncovered lines are the `GeometryRequest` declaration attribution and the overlay panel's `close` override (`orderOut` is covered). Core/decoder line hits do not prove every branch, native allocation, language/format or watchdog behavior.

## Remaining boundaries

`VisionScrollOffsetEstimator` still performs in-process translational registration. Its synchronous `ScrollStitcher.add/candidateShifts` path is used by `DirectionalScrollStitcher` and detached session analysis, but `ScrollCaptureSession.finish(.user)` also synchronously drains pending frames on the UI actor. A later migration must cover both paths, axis orientation, hash/row validation, undo generations, final flush and bounded retirement; replacing only the estimator facade with blocking IPC would be insufficient.

Clipboard AVPlayer playback and explicit user-requested OS Quick Look remain separate boundaries. Stage-2 adapters/condition-driven lifecycle/persisted health integration and audio/TCC/signing/performance verification before deciding capture isolation remain required. Real CoreML/model performance, full Xcode app build, Developer ID/notarization, macOS 13/Intel and real quit/recording interactions were not exercised. Host filesystem/rasterization/JSON/base64/pasteboard/SQLite/import-export/UI and AppKit/GPU/system memory are not contained by this increment. No arbitrary host crash, system-wide OOM or power-loss guarantee. GUL-399 remains in progress.
