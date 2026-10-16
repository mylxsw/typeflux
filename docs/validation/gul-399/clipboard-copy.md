# GUL-399 — explicit clipboard image copy conversion

This increment depends on #540 (`f6d1a788`), not on an assumed main landing. #540 and #538 were still open with their original bases at final review. The overall issue remains in progress.

## Contract and ownership

- Stored screenshot PNG validation and TIFF conversion use the existing independent media helper's new `copyClipboardImage` operation. The original PNG bytes are returned unchanged and compared with the input. The host no longer calls `NSImage(data:).tiffRepresentation` in `SystemClipboardContentActions`.
- Accepted image limits match current clipboard capture: 10 MiB PNG, 16,384 axes, 16,000,000 pixels. This deliberately differs from workflow copy's 20 MiB / 8,192 axes / 16,777,216 pixels. Oversized historical files remain on disk and are refused, not deleted. The reused reader still has a 20 MiB + 1 hard read cap if a source grows after its initial metadata check. The helper requires PNG and a complete first frame; TIFF uses the existing orientation and DPI conversion.
- Reuse the workflow preparation's two admissions, two 80 MiB representation reservations, and existing preview pool (two children, three-second deadline). No queue, new executable, target, packaging path, or producer replay. Fixed-name PNG/TIFF outputs have bounded lengths/signatures, UUID/version/operation/format/dimension checks, descriptor-relative reads, and confirmed-reaping leases. Request/response remain 1 KiB / 16 KiB; combined representations are at most 80 MiB.
- `ClipboardImageRevision` rejects empty, oversized, symlink and nonregular stored images. Path/device/inode/size/mtime/ctime are checked before preparation, after extraction, immediately before the pasteboard commit, and before a delayed paste. These checks reject observed replacement; they are not an immutable filesystem transaction.
- `ClipboardContentAction` owns one explicit action per caller. Cancellation retains its slot until preparation actually returns, including uncooperative work. Account notifications, original authorization, entry membership, selection/result generation, owner release and shutdown fence late commits. A view's intentional dismissal after a successful commit cannot cancel the intended focus-return delay. No fresh account/scope grants access to an older result.
- The history panel now stays open during nontext preparation and on failure. A successful commit closes it before the focus delay and sends one shortcut. Launcher paste uses an async completion callback; copy stays open. The legacy workflow UI boundary checks the main thread before entering MainActor and snapshots authority synchronously with the click. There is no task created by a getter.
- Files still copy as file URLs or newline-separated paths, with the existing 1,000-file / 1 MiB path-payload bounds and a final existence check. Text actions retain their existing contract. Preparation failure never clears the pasteboard. A failed pasteboard write is reported once and never sends a shortcut; the OS may already have accepted the preceding clear, so no rollback or zero-effect claim is made. A changed pasteboard revision suppresses delayed paste rather than pasting somebody else's content.
- AppCoordinator fences both action owners before awaiting termination cleanup. Workflow stop invalidates its action generation; launcher visibility cancels pending preparation. Original images, history and operation receipts are not rewritten. No workflow, Agent action, capture or paid request is rerun.

## Focused validation

Implementation and self-review preceded the single functional pass. **32 distinct Swift methods passed: 28 XCTest and 4 Swift Testing**, without functional failures or retries.

| Scope | Methods | Behavior |
| --- | ---: | --- |
| ClipboardCopyIsolationTests | 11 | Original bytes, actual helper conversion, malformed/oversized/symlink/source replacement, protocol bounds, admission, owner release, cancellation/account/deletion, shutdown, single commit, changed pasteboard, failure |
| SystemClipboardContentActionsTests | 3 | Private pasteboard PNG/TIFF and file/plain-path compatibility, missing content |
| WorkflowControllerProcessingTests | 6 | History copy/paste focus, failures retain panel, no extra shortcut, text compatibility |
| AskClipboardPluginTests | 4 | Launcher text/file outcomes, completion callback, failed write, deleted entry and late preparation |
| WorkflowImageIsolationTests | 6 | Shared conversion/protocol compatibility, supported types/DPI/orientation, changed files, output validation and retained cancellation |
| MediaWorkerTests | 2 | Real helper with harmless crash/hang fixtures, shutdown and no replacement/replay |

All pasteboards were private named test boards or injected sinks. No real paste events, user clipboard capture, app launches, network/provider requests, microphone, TCC or workflow effects were exercised. Two packaging tests and a real copied-helper PNG/TIFF probe passed; the probe asserted byte-for-byte original PNG retention. No visual layout changed and no new screenshot was required.

Commands used the sanitized `scripts/test_runtime.child_environment()`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in the bundle and media helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
python3 -m unittest scripts.tests.test_media_packaging
```

No discovery rebuild occurred between the instrumented build and prebuilt execution. Exact filter:

```text
^Typeflux(?:Focused)?Tests[./](?:MediaWorkerTests[./](?:testRealHelperImagePDFMalformedAndCrashHangFixtures|testShutdownCancelsRunningChildAndRejectsNewWork)|ClipboardCopyIsolationTests[./]|SystemClipboardContentActionsTests[./](?:testWritesFilesAsURLsOrPaths|testWritesStoredImagesAsPNGAndTIFF|testWritingFailsWithoutContent)|WorkflowControllerProcessingTests[./](?:testPastingFilesWritesThePasteboardThenSendsPaste|testPastingFilePathsAsPlainText|testFailedPasteboardWriteDoesNotSendPaste|testPastingCopiedTextInsertsIt|testCopyingAnImageWritesThePasteboardWithoutPasting|testFailedImageCopyKeepsThePanelOpen)|AskClipboardPluginTests[./]`(?:text pastes after closing and copy keeps launcher open|files copy and paste through existing content actions|deleted entries and missing files cannot change clipboard or paste|late image preparation cannot write a deleted launcher entry)`|WorkflowImageIsolationTests[./](?:testProtocolRejectsMixedOperationsUnboundedDimensionsAndCopySizes|testChildPreservesSupportedTypesDPIAndCopyRepresentations|testRealHelperAndChangedContentNeverReusePathOrTimestampAsProof|testClipboardRejectsMissingTruncatedSymlinkAndInvalidHeadersWithoutChangingOriginal|testAdmissionRetainsCancelledUncooperativeWorkUntilItReturns|testCopyNormalizesOrientationAndCacheQuotaNeverEvictsOutputs))
```

Preparation build wall times were 48.42, 195.84, 95.30, 29.14, 160.56, 69.49, 79.14 and 35.46 seconds. Builds 1/2/4 failed compilation (legacy controller actor boundary/shadowed callback, an old mock signature, and an optional controller bridge respectively); these were fixed before any tests. Other builds passed; the last change before the functional pass marked the affected history UI fixtures MainActor. Focused runner: 15.32 seconds. Packaging command: 0.197 seconds; copied-helper probe: 0.145 seconds. Tracked total **729.012 seconds**, excluding audit, extraction and outer Python startup for the probe.

## Coverage and evidence

Changed executable lines: **129/143 = 90.21%**. `clipboard-copy-coverage.json` lists per-file attribution and all misses. All 10 raw profiles (three host, six direct helper, one copied helper) belong to the same final build, were individually validated by `llvm-profdata show`, and merged without warnings after children and the probe completed. No prior passing result/profile or mixed counter layout was reused. New Sources were included with `git add -N`; extraction supplied the helper as `llvm-cov --object` so helper-only code is counted.

Matching local evidence: `.build/clipboard-copy-validation/final`; task runners `gul-399-copy-test.py` and `gul-399-copy-probe.py` in the task workdir. These paths are reproducibility notes, not attached artifacts.

- XCTest SHA-256: `8d01c39dfe10bfe1fd5ddef4dbad519aca2f04aaaf7208c69865a0c67b4dd752`
- Helper SHA-256: `a7e43516b2a78e3ea1f79dbf6a4fb4691026916a991c5bd3c0ab8669d669ee7f`
- Uncovered 14 lines: four AppCoordinator quit bridges, four composer dispatch lines, one launcher-hide bridge, two default action callbacks, the real pasteboard revision accessor, and two workflow-stop bridges. The action/worker tests exercise the underlying fences with injected owners; this is not real AppKit quit/recording or paste-event validation.

The app and helper Mach-O minimum deployment targets remain macOS 13.0. `nm -gU` found zero media-runtime symbols in the app and 67 in the helper. The XCTest runtime reports macOS 14; none of these checks is macOS 13/Intel hardware validation.

## Remaining boundaries

Host filesystem metadata/read/copy, raw byte allocation, pasteboard IPC and explicit shortcut posting remain in-process. Final metadata checks can block in the filesystem and cannot close every external mutation race. Reservations do not bound AppKit, pasteboard-server, GPU or system-wide memory. A failed commit can have partially changed the pasteboard; it is never retried automatically.

Clipboard OCR still uses in-process Vision; inline/audio playback still uses AVPlayer. Explicit OS Quick Look remains a user-requested OS/UI boundary. Stage 2 adapter/condition-driven lifecycle and persisted-health integration remain incomplete (registry has three stores; media/native/inference are separate domains). Audio/TCC/signing/performance verification is required before deciding microphone capture isolation. Real CoreML/performance, full Xcode builds, Developer ID/notarization, macOS 13/Intel hardware and actual quit/recording remain unverified. No full suite was run. Line coverage is not branch, native allocation, OS memory failure or arbitrary-host-crash proof.
