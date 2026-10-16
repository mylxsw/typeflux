# GUL-399: recording saved/recovery posters and toast ownership

This increment is based on `6de3c67678b937e4796ec007b96dda46cba82e10` (`agent/arch-gpt-astra/gul-399-recording-timeline`, #554). It does not repeat playback or timeline extraction. The next native boundary is recording export and its publication/authorization transaction.

## Contract and ownership

`ScreenRecordingPreviewMedia.thumbnail` is now explicitly asynchronous. `ScreenRecordingTimelineLoader.thumbnail` uses the existing media helper's new `recordingPosterGIF`/`recordingPosterVideo` operations. A video poster extracts only time zero with preferred orientation; it does not scan audio, play, or generate a timeline batch. GIF uses its first complete frame and requires the actual GIF type. No encoded-original host fallback remains in this path.

- Video source: local, resident, regular, non-symlink final file, path at most 4 KiB, at most 8 GiB. GIF: at most 50,000,000 compressed bytes, 1–300 frames. The separate GIF limit can refuse an oversized exported GIF's preview while retaining its file and explicit actions.
- Native source dimensions: positive finite, at most 8192 on either axis and 16,777,216 pixels. Exactly one raw RGBA raster fitting 200×120, exact stride/length and fixed no-follow file reading. UUID/version/operation/mixed-payload validation; 32 KiB request ceiling and 16 KiB parent response ceiling. Originals remain unchanged.
- Reuses the timeline's two host admissions and existing two-child/30 s domain/35 s helper alarm. No new executable, packaging target or DI pool. File inspection is asynchronous and shares bounded admission; cancellation is checked before admission and after detached work. No queue or automatic retry. Capacity exhaustion fails closed rather than starting replacement work.
- One private streamed input copy per missing poster, 0700 directory/0600 file. Video refuses external AV references. Source device/inode/size/mtime/ctime checked before/after preparation and again before an explicit file action. These snapshots are not immutable filesystem transactions.
- Reserves 192,000 bytes from the existing shared pixel budget before preparation. Ownership survives both host completion and actual child collection; CGDataProvider separately retains the pixel lease through display lifetime. Supplied validated timeline rasters are reused with their original provider lease and are not decoded again. Oversized supplied rasters are ignored.
- Original presentation generation owns one task and one action task. Actual orderOut/close/miniaturize, replacement, account/token changes and owner release retire the model, clear pixels, URL and controls, and fence late results. An old retained window's retirement callback cannot clear a newer presentation. Timed hiding also checks the original generation.
- File buttons prepare a bounded read-only source check, then perform the explicit callback with no await between authority check and invocation. Duplicate busy actions and stale generations are refused. Decoder failure alone preserves fallback/file controls; missing/changed/inaccessible sources or admission failure withdraw the card. No automatic open/copy/discard/recovery/export/recording retry. Drag supplies a file URL only while the current model is ready; an already-started OS drag remains an OS boundary.

Copy/inspection is outside the child deadline and may be uncooperative; occupied slots remain held. Two poster copies may consume 16 GiB, in addition to existing playback/timeline copies. The budgets do not bound all filesystem, ImageIO/AV, AppKit/GPU or OS allocations. Host raw-image construction and explicit filesystem/NSWorkspace/pasteboard actions remain boundaries. Source replacement after the final check and already-dispatched OS actions are not rollback guarantees.

## Validation

Focused suites cover synthetic GIF orientation/fit/type/frame bounds; silent rotated video; malformed input and original retention; missing raw files and source mutation; sparse over-limit files; shared admission and retained cancellation; independent CGImage pixel ownership; supplied-image reuse; duplicate/stale/deleted file actions; replacement/account/actual hide/close/miniaturize/owner release; late decoder completion; actual toast pixels and an injected Copy click. Shared timeline, worker fault/retirement and protocol compatibility methods are included. The visual method covers four style/appearance argument cases. No real user clipboard write, app launch, audio output, capture, TCC, provider/network or workflow action is performed.

Commands use sanitized `scripts/test_runtime.child_environment`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l <test-binary> / <helper>  # __llvm_covmap and __llvm_prf_cnts
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
python3 -m unittest scripts.tests.test_media_packaging
python3 gul-399-toast-probe.py
```

No discovery rebuild, simultaneous SwiftPM/UI jobs or full-suite run. Packaging probes launch the actually copied app-bundle helper on synthetic GIF and verified no-audio video, check exactly one bounded raw file and unchanged private input. No playback command is sent.

Final **20/20 distinct methods passed**: 18 XCTest + 2 Swift Testing; the visual method has four argument cases. Scope: 12 new RecordingToastIsolationTests, 2 existing timeline ownership/batch methods, 2 worker fault/shutdown methods, 2 protocol methods, the actual toast Copy UI method and the four-case visual method. Two packaging checks and both copied-helper poster probes passed. Screenshot visually inspected.

Exact filter (literal backticks preserved):

```text
'^Typeflux(?:Focused)?Tests[./](?:RecordingToastIsolationTests[./]|ScreenRecordingUIInteractionTests[./]`saved and recovery toasts keep owned windows and file actions`|ScreenRecordingVisualTests[./]`toolbar capsule editor and toast use the approved surfaces`|RecordingTimelineIsolationTests[./](?:testRealHelperBatchPreservesRotationOrderAndPixelLeaseAfterModelRelease|testLeaseKeepsPixelsUntilHostAndChildBothRetire)|MediaWorkerTests[./](?:testRealHelperImagePDFMalformedAndCrashHangFixtures|testShutdownCancelsRunningChildAndRejectsNewWork)|MediaProtocolTests[./](?:testInvalidIdentityVersionAndAmbiguousResponsesFailClosed|testCommandFramesReadFailureAndSuccessfulResponse))'
```

Seven preparation/correction builds all passed, wall seconds **222.26 / 91.47 / 37.58 / 60.74 / 36.42 / 36.43 / 42.88**. Functional commands: **14.07 / 37.94 / 23.99 / 22.76 / 22.82 s**. First run passed all 18 XCTest methods, then an old Swift Testing UI fixture accessed uninitialized NSApp and trapped; the visual method did not execute. The next three runs each passed 19/20 methods; the same UI method failed button lookup/readiness (respectively 1, 2 and 3 reported issues). Added fixture NSApplication initialization and window-tree/title-aware waiting. Diagnostics then established the card was withdrawn, not merely inaccessible: the fixture overlapped a timeline, immediately cancelled recovery and saved card. The UI fixture now injects unrelated timeline output and collects the previous card. Source self-review also fixed cancellation-before-admission for file inspection and added a deterministic saturated-admission cancellation assertion. Final fresh build ran the entire 20-method scope successfully, including actual AX Copy with an injected sink. No production or test source changed after that final build.

Packaging reported **0.144 s**, copied-helper GIF/video probe **0.261 s**. Total tracked build/test/probe time **649.765 s**, excluding packaging interpreter startup, audit, archival, coverage extraction and screenshot inspection. No full suite or full Xcode build.

Changed executable lines: **195/197 = 98.98%**, compared to the actual #554 base. Only the two delayed-hide callback lines are unhit. This is line coverage, not all-branch/native-allocation/OS-action/watchdog proof; callback definition line hits do not imply real Finder/open/clipboard actions were exercised.

Coverage uses only **15 fresh profiles from one final binary** (3 host, 10 direct helpers, 2 copied helpers). Every raw profile was individually validated; merge completed without warnings. Earlier interrupted/failed-run profiles were excluded. New Sources were included with git add -N; helper supplied as llvm-cov --object. Matching binaries/profiles are archived in `.build/toast-validation/final`.

- XCTest SHA256: `a8df4972391bfab82ddba9177b192e0aebf8c4599ae06a9d8388e9ec7705d1e1`.
- Helper SHA256: `6c84ab8f88a1ed858e724e527745f4659df9a2f904a719d01c68e69f2a10d391`.
- App/helper minimum OS: 13.0. Host has 0 exported media-runtime symbols, helper 155 (`nm -gU`). Existing XCTest runtime reports macOS 14; none of this is macOS 13/Intel hardware verification.

`recording-toasts.png` shows the actual saved-toast component with synthetic pixels, not a full-app capture.

## Remaining approved work

`ScreenRecordingExporter` still owns AVAssetExportSession/composition/trim/GIF native work and detached/progress tasks. Publication already dispatched by `files.publish` can complete after revocation; this increment does not claim to repair that transaction or provide zero-effect rollback. Originals/receipts, stable action identity and no replay must be preserved in the next export slice. Live capture/audio-meter ownership, lifecycle/health integration, signing, CoreML/performance, full Xcode build, actual quit/recording and macOS 13/Intel/device verification remain. GUL-399 is still in progress, not ready for acceptance.
