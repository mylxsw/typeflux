# GUL-399: clipboard OCR and explicit copy ownership

This increment is based on #541 (`03f6750d15ef404c844664fd51eab15f84f5f16c`), which was still open against `agent/arch-gpt-astra/gul-399-source-app-icons` at delivery. It does not duplicate the PNG/TIFF copy conversion. The overall approved stability plan remains in progress.

## Behavior and boundary

Clipboard file-to-text recognition now uses the existing independent media executable. `MediaOCRDecoder` owns ImageIO and Vision; the host receives only validated strings, never Vision observations or closures. Recognition remains local, accurate, language-corrected and automatically language-detected. Blank images return no text; unreadable images, unavailable workers and oversized results throw. Raw error strings and image paths are not logged by the clipboard OCR facade.

The dedicated OCR pool admits two children, with a 30-second host deadline and the existing 35-second helper alarm. The facade admits two tasks before detached work; cancellation retains admission until actual work returns. Private input copies and child slots retain the existing confirmed-reaping lease. App lifecycle wiring fences and awaits this pool. No request is retried.

The contract is a 1 KiB request and 2 MiB response, at most 10 MiB input, 16,384 pixels per axis and 16 million pixels. PNG/JPEG/GIF/WebP/TIFF/HEIC use the first complete frame, with orientation applied in the child. Output has at most 1,024 lines, 16 KiB per line and 256 KiB total including separators; NUL is rejected. No geometry is sent. These bounds limit owned work, not all Vision/framework/system allocations.

`ClipboardContentAction.startText` shares the explicit copy action owner, so OCR and image copy cannot overlap for one owner. The click captures a source revision; after recognition it checks cancellation, original authority and source revision immediately before the single text commit. The history caller checks account identity/generation, entry membership, current selection, panel visibility and action generation. Account events, owner release, pending-action cancellation and shutdown fence results. Empty results show the existing no-text notice; failure shows unavailable without clearing the clipboard. Existing text clipboard service writes remain a host-side, void-returning operation: this change cannot establish OS-level write durability or rollback. No paste shortcut is sent, no live pasteboard is reread, and no producer or write is replayed.

Source checks reuse path/device/inode/size/mtime/ctime and regular/resident-file validation. This is not an immutable filesystem transaction. External mutation after the final check remains possible; uncooperative filesystem work remains in-process with bounded admission.

## Shared OCR audit and deliberate remaining slice

`DIContainer.imageTextRecognizer`, `TiledImageTextRecognizer`, `AskConversationModel.makeLauncherScreenshot`, `VisionSensitiveInfoScanner` and `AskTranslationPanelCoordinator.openScreenshot` still use the shared raw-CGImage recognizer. `RecognizedText.Line.RangeLocator` closes over `VNRecognizedText` to compute exact UTF-16 range bounds, used by selection and sensitive-text redaction. Replacing it with proportional or line-only boxes would silently weaken geometry. This increment therefore isolates only clipboard file-to-text, through a separate facade; it does not claim shared screenshot/translation/redaction Vision isolation. That migration needs bounded serializable exact-range geometry and raw-image/tile ownership as its next coherent boundary.

Clipboard AVPlayer playback, explicit OS Quick Look UI, stage-2 module adapters/health integration and audio/TCC/signing/performance decisions remain unfinished. Registry health currently covers three stores. Real CoreML performance, full Xcode/release signing/notarization, macOS 13/Intel hardware and actual quit/recording integration were not exercised. No arbitrary host-crash, system-wide OOM or power-loss guarantee is made.

## Validation

Implementation and self-review preceded the focused test pass. Fresh direct builds used `swift build --build-system native --build-tests --enable-code-coverage --jobs 4` through the task-local sanitized `scripts/test_runtime.child_environment` runner. The first build failed only in a new test fixture's `ManagedProcess.Result` argument order/missing exit code (226.81 s); after it exited, the fixture was corrected and selection authority was tightened. The final build passed in 60.91 s. No test had run before these changes.

Both final XCTest and helper binaries contained `__llvm_covmap` and `__llvm_prf_cnts`. No test-discovery rebuild was inserted. The subsequent command was `swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <scope>` using these exact suites/methods:

- `ClipboardOCRIsolationTests`: all 8 methods; malformed/bounded protocol, injected child engine, real helper text/blank/malformed/reread, mutation, uncooperative cancellation/admission, duplicate/owner release and copy authority/failure outcomes.
- `SystemClipboardContentActionsRecognizerTests`: both methods; injected recognizer and throwing failure distinction.
- `SystemClipboardContentActionsTests/testRecognizesTextInImages`: real production default facade.
- `WorkflowControllerProcessingTests/testCopyImageTextCopiesRecognizedText` and `testHistoryOCRFailureAndDeletionNeverWrite`: actual history dispatcher, private source files and injected clipboard service.
- `ClipboardCopyIsolationTests`: `testDuplicateActionAndCancellationRetainAdmissionUntilPreparationFinishes`, `testDeletionOrRevocationAfterAwaitNeverWrites`, `testOwnerReleaseCancelsLatePreparation`, `testIntentionalDismissalAllowsOnePasteButChangedClipboardOrAccountStopsIt`, `testShutdownFencesPendingAndFutureActions`; shared owner compatibility.
- `MediaWorkerTests/testRealHelperImagePDFMalformedAndCrashHangFixtures` and `testShutdownCancelsRunningChildAndRejectsNewWork`: shared child ownership/fault machinery.
- `MediaProtocolTests/testInvalidIdentityVersionAndAmbiguousResponsesFailClosed` and `testJPEGEnvelopeRejectsMixedWrongTypeBrokenBase64AndPageOrdering`: existing response compatibility.

**22/22 XCTest methods passed in one pass**, 14.03 s command wall time. No functional retries. Two packaging tests passed (0.192 s runner). A copied app-bundle helper probe initially used a 2×2 blank PNG, which Vision rejected; the probe alone was corrected to a 200×200 blank PNG and passed (0.225 s). No product code or binaries changed after the final build. The original probe's failure profile is retained. Build/test tracked total: 301.75 s; plus successful packaging/probe: 302.167 s. Initial failed probe, binary archival, coverage extraction and audit overhead are additional, not included in that total.

Changed executable line coverage is **121/125 = 96.80%**, including new sources and helper-only code via `llvm-cov --object`. All 11 fresh profiles (3 host, 6 direct helper, 2 copied-helper probes) come from the same final binary set, were individually validated, and merged without warnings. No previous increment profiles or different counter layouts were mixed. Matching artifacts were saved under `.build/clipboard-ocr-validation/final`; the committed JSON lists per-file coverage. Four uncovered lines are DI/quit bridges. Full line hits in the decoder do not prove every guard branch, native allocation, language, format, watchdog or real quit path.

Final XCTest SHA-256: `41a1d671e65cfc88e98bcb2f54d693ef8e984e781d97d6e764bd5668c33e54b7`.
Helper SHA-256: `b2e729c05dcd386820940fac4f450e6f44b4d8060356376a3f0f7607d8dd982c`.
`nm -gU` finds zero media-runtime module symbols in the host and 72 in the helper. Both app/helper Mach-O minimum OS values remain 13.0; this is not macOS 13 hardware validation. No new packaging target, visual layout change or screenshot. No full suite, real clipboard write/paste event, screen/microphone capture, network/provider call, app launch, TCC or release signing exercise.
