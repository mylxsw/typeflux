# Recording timeline extraction isolation

This increment is based on #553, `b9903cd12b987f43130387db3e4d11590e53a524`, and does not complete GUL-399. #553, #552 and #549 were still open when this increment was delivered; their existing bases are unchanged.

## Behavior and ownership

`ScreenRecordingPreviewMedia.load` now delegates to an explicitly asynchronous, admitted batch in the existing media executable. The child reads duration, transformed video dimensions and frame rate, generates ten orientation-correct thumbnails at `duration * index / 10`, and scans every audio track across the whole recording into 160 absolute peak buckets. It preserves the previous buffer-timestamp bucket placement and maximum-across-tracks semantics; it does not substitute the clipboard's 600-second/180-bucket or Ask's 30-second/80-bucket waveform. There is no playback, capture, producer replay or source deletion in extraction.

The host admits two batches before detached work and reserves 1,920,000 bytes of shared pixel capacity for each batch before dispatch. A batch streams one private input copy, not ten copies. The dedicated `MediaWorker.recordingTimeline` domain has two child slots, a 30-second child deadline, the existing 35-second independent helper alarm and DI/quit fencing. `MediaLease.retained` holds admission/pixel ownership until both host completion and actual child collection. Each returned CGImage's data provider separately retains the shared pixel lease, including images retained after the result/model is released. No app-lifetime thumbnail cache is introduced.

Input: local, resident, regular, non-symlink final file, path at most 4 KiB, 8 GiB per recording. Source device/inode/size/mtime/ctime are checked before preparation and after extraction. The original is never deleted. Private directories are 0700 and streamed input files 0600. AV asset external references are forbidden. The two timeline slots can hold 16 GiB of private copies in addition to any concurrent playback copies; streaming uses the existing 64 KiB buffer. Copy/filesystem work is outside the child deadline and can be uncooperative; it keeps its bounded slot. Metadata checks are not an immutable filesystem transaction.

Protocol: 1 KiB request, 16 KiB response, UUID/version/operation/mixed-payload checks. Metadata must be finite: positive duration up to 24 hours, positive axes up to 8192 and at most 16,777,216 source pixels, frame rate 0–240. Exactly ten raw RGBA rasters, each at most 200×120, fixed paths, checked stride/exact byte count, no-follow regular-file reads. Original encoded media is never parsed by the host timeline path.

Audio: at most eight tracks, existing channel/sample-rate layout retained, float32 interleaved PCM, at most 4 MiB per buffer and 512 MiB total across all tracks, with a 20-second scan budget checked between buffers. Native calls that fail to return are covered by the child process deadline. The result is **whole-recording waveform or unavailable**, never a truncated window labelled complete. No tracks is a separate `absent` state. Audio failures preserve successfully extracted metadata/thumbnails; frame/metadata failure rejects the batch. The coordinator reports unavailable, retains the original and keeps the existing export entry available when playback supplied valid duration. No automatic extraction retry is added.

The existing original access/epoch/generation checks fence publication. Actual panel hiding, account changes, cancellation and owner release clear private state and reject late output. The UI distinguishes preparing, no track and unavailable in five languages. Screenshot: `recording-timeline.png`, inspected after rendering the actual timeline with synthetic source and injected extraction failure.

## Validation

**34 distinct Swift methods passed in one functional pass:** 19 XCTest and 15 Swift Testing methods (the existing permission test has three argument cases). No functional failures or retries.

- 10 `RecordingTimelineIsolationTests`: envelope/finite/dimension/PCM bounds; whole-duration peak placement beyond 600 seconds and cross-track maximum; real helper rotated two-color movie ordering; native two-audio-track extraction; malformed originals retained; changed source and missing raw output rejected; sparse oversized and invalid paths; pixel ownership; uncooperative cancellation/admission/shutdown; late results after actual panel hiding/account/retirement; truthful failure UI and retained export/source.
- 9 coordinator methods and 5 presentation methods: directly affected prepare/retire/export/recovery callers.
- 1 redesign recovery method: actual `ScreenRecordingPreviewMedia.load` metadata, ten thumbnails and waveform.
- 3 recording preview isolation methods: preview failure, account/hide and presenter release compatibility.
- 4 `MediaWorkerTests`: private copy/confirmed collection, retained admission, harmless real crash/hang children and shutdown.
- 2 `MediaProtocolTests`: existing envelope and helper-command compatibility.

Two packaging tests passed. An actually copied app-bundle helper decoded the synthetic no-audio rotated movie, returned ten bounded raw RGBA files and metadata, and left its private input unchanged. No play command was sent by this increment's probe. Existing selected presentation tests use verified no-audio fixtures for their explicit playback controls. No real audio output, capture, TCC, user clipboard/paste, network/provider/workflow actions, full suite, full Xcode build, signing or hardware exercise occurred.

Commands (task-local wrappers use `scripts/test_runtime.child_environment`):

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l <test-binary> / <helper>  # verified __llvm_covmap and __llvm_prf_cnts
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <explicit scope below>
python3 -m unittest scripts.tests.test_media_packaging
python3 gul-399-timeline-probe.py
```

Explicit filter:

```text
^Typeflux(?:Focused)?Tests[./](?:RecordingTimelineIsolationTests[./]|ScreenRecordingCoordinatorTests[./]|ScreenRecordingPresentationTests[./]|ScreenRecordingRedesignTests[./]`recovery loads original options and deleting only affects owned sessions`|RecordingPreviewIsolationTests[./](?:testFailedPreviewRetainsOriginalAndDoesNotRepeatCaptureOrLoad|testHideAndAccountRetirementClearPixelsAndBlockExportButKeepSource|testPresenterOwnerReleaseAndActualPanelHideRetirePlayback)|MediaWorkerTests[./](?:testCopiedInputIsPrivateAndRemovedOnlyAfterConfirmedCollection|testTwoRetainedChildrenBoundAdmissionAndShutdownFences|testRealHelperImagePDFMalformedAndCrashHangFixtures|testShutdownCancelsRunningChildAndRejectsNewWork)|MediaProtocolTests[./](?:testInvalidIdentityVersionAndAmbiguousResponsesFailClosed|testCommandFramesReadFailureAndSuccessfulResponse))
```

First preparation build **51.24 s failed** because the old synchronous decoder's exhaustive switch needed the new operation refusal case. Fixed before tests. Final build **241.76 s passed**. Focused test command **24.17 s** (XCTest 10.090 s, Swift Testing 3.506 s). Packaging reported **0.142 s**, copied-helper probe including packaging/launch **0.396 s**. Tracked build/test/probe sum **317.708 s**, excluding packaging interpreter startup, audit, archival, coverage extraction and screenshot inspection. No source or test input changed after the final build.

Changed executable lines: **190/198 = 95.96%**, against the actual #553 base, not overall project coverage. All ten fresh profiles are from one final binary set: three host, six direct helper, one copied helper. Every raw profile was individually validated and merged without warnings; helper supplied as `llvm-cov --object`, new Sources included with `git add -N`. No previous profiles or differing counter layouts were reused. Matching evidence is in `.build/timeline-validation/final`; report `recording-timeline-coverage.json`.

- XCTest SHA-256: `945abe9dfa904ec0f6a16ccabd6f0d5f4599ba78ae8f59ebadfb4bd5f058785b`
- Helper SHA-256: `2ca7a12d7ccd03fcc2affa17cbd64db211d905a33107d565b7c0d6a721102f79`
- App/helper Mach-O minimum OS remains 13.0. Host has zero exported `TypefluxMediaRuntime` symbols; helper has 149 (`nm -gU`). This is not macOS 13/Intel hardware verification.
- Eight uncovered lines: four DI/quit bridges, one failed raw-provider allocation cleanup, three native partial-audio failure recovery lines. Line coverage does not prove all branches, every format/track layout, allocation failure, deadline expiry, real quit or filesystem durability.

## Explicit remaining boundaries

The saved/recovery toast's **single thumbnail** still calls `ScreenRecordingPreviewMedia.thumbnail` (GIF ImageIO/video AVAssetImageGenerator) in the host, and its separate view lifetime needs migration next. This increment deliberately covers the editor batch only. `ScreenRecordingAudioMeter` remains the live-capture meter and is not changed by file waveform isolation.

`ScreenRecordingExporter` still owns native composition/trim/GIF processing in the host. Its existing detached filesystem publication is not an atomic cancellation/authorization commit: an already dispatched publication can finish after revocation. Original retention and no automatic replay remain, but zero effect/rollback is not promised. Capture/TCC ownership is separate from file preview. Stage-2 adapters/persisted health, remaining native paths, signed/hardware/CoreML/performance and actual quit/recording validation remain unfinished. Host filesystem/raw bitmap construction/UI/pasteboard/SQLite and AppKit/GPU/system memory are boundaries; this does not guarantee immunity to arbitrary host crashes, OS-wide OOM or power loss.
