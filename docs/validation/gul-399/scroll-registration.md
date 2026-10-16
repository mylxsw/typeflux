# GUL-399: scrolling frame registration

This increment is based on `9ea5d614c65935daf4ede865346c14b3af0b4c90` (#545), which targets the still-open main integration #544. It does not replace that main landing entry or merge any PR.

## Delivered boundary

`VNTranslationalImageRegistrationRequest` now executes only in the existing media helper. The host asynchronously sends two equally sized raw RGBA frames and receives an optional finite vertical translation. Both signs remain candidates, and the existing hash voting, row-distance search, pinned-bar widening and overlap checks still decide whether pixels can be appended. Native failure removes this candidate source; it does not bypass validation, rerun capture, or send another scroll event.

- `registerFrames`: 1 KiB request/response, UUID/version/operation and mixed-payload validation. Maximum 16,384 on either axis and 16,000,000 pixels **per frame**; two frames total at most 128,000,000 bytes under the 128 MiB transport ceiling. This accommodates common 4K/5K regions. Larger regions are refused, never silently downscaled.
- Two preparation admissions before detached serialization; a separate two-child/3-second `MediaWorker.frameRegistration` domain, existing failure budget, 35-second child alarm and confirmed-reaping leases. Inputs remain private until caller return and actual child collection. Shared executable does not imply shared OCR failure state. No target or packaging changes.
- Native candidates and known scroll distances are bounded before integer conversion. Pure overlap validation rejects extreme signed integers before `abs`, including `Int.min`.
- `ScrollStitcher`/`DirectionalScrollStitcher` retain synchronous **pure** APIs for algorithm fixtures and prepared candidates. The production session exclusively uses `addPreparingOffsets`; there is no blocking IPC in a getter or synchronous stitch call. The old synchronous estimator seam is only used by injected pure fixtures.
- Both realtime analysis and final user-requested drain run off the main actor. Finishing stops input/driver/timer immediately, collects the existing analysis once, processes at most the final pending frame, then assembles the export asynchronously. Repeated finish/undo/automatic-step requests cannot add operations while draining; cancel remains available. Non-user endings discard in-flight candidates and export the already accepted image.
- One latest-frame inbox and one scheduled delivery replace a task per incoming frame; source errors are admitted once. Two global analysis admissions are retained through uncooperative work. Undo/version, cancellation, account events, actual panel order-out/close and owner release revoke late commits. Cancellation clears stored segments. Normal dismiss clears hide hooks before ordering panels out, so shutdown is not replayed recursively.
- No raw frames, native errors, or source content are logged. There is no workflow/Agent/clipboard/capture replay.

The synchronous source-analysis closure, signature search, crops, horizontal transposition and final raster assembly remain host operations. Cancellation fences their result but cannot forcibly interrupt native allocation or uncooperative host callbacks. A two-direction initial comparison can issue two sequential registration requests; three seconds is a **per-child** deadline, not a whole-session latency promise. Live capture and driver permission behavior are unchanged and were not exercised here.

## Focused validation

Implementation and self-review preceded the single functional test pass. Two direct preparation builds passed: **315.42 s** and **162.34 s**. The second incorporated review findings: a 16 MP frame limit (the initial 8 MP choice excluded some normal high-resolution regions), owner cleanup and actual panel-hide cancellation. No build or functional test failed; no tests were retried.

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in the test binary and media helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
```

The task-local `gul-399-scroll-test.py` uses `scripts/test_runtime.child_environment`; there was no intervening discovery rebuild. **71/71 XCTest methods passed**, 69.82 s command wall time (30.867 s XCTest execution):

| Scope | Methods | Reason |
| --- | ---: | --- |
| `ScrollRegistrationIsolationTests` | 9 | Protocol/malformed pairs, overflow, real helper, native failure/candidates, both axes/undo, retained cancellation admission, harmless crash/hang children, actual panel hide and coalesced inbox |
| `ScrollCaptureSessionTests` | 35 | Realtime/final analysis, automatic/manual controls, final pending frame, no duplicate events/export, undo/version, source failure, account revocation, owner release and high-frequency callbacks |
| `DirectionalScrollStitcherTests` | 6 | Axis/transpose, reverse scroll, pinned bars and output limits |
| `VisionScrollOffsetEstimatorTests` | 2 | Signed candidates and actual synthetic translated-image registration |
| `ScrollStitcherTests` | 11 | Exact pixels, fixed/blurred/sticky bars, redrawn/repeating content, estimator validation, undo and budget |
| `ScreenshotCoordinatorTests` | 3 | Scrolling handoff, cancellation and explicit screenshot follow-up |
| `MediaWorkerTests` | 3 | Confirmed collection, admission retention and shutdown |
| `MediaProtocolTests` | 2 | Identity and command framing compatibility |

Exact selected methods for the partial suites:

```text
ScrollStitcherTests: testFramesJoinIntoTheExactPage, testPinnedHeaderAndBottomBarAppearOnce,
testABlurredBandUnderThePinnedHeaderJoinsIt, testStickyLinesAtTheTopStillLetLaterFramesLineUp,
testRedrawnContentStillLinesUp, testARepeatingLayoutDoesNotFoolTheAlignment,
testTheEstimatorsShiftIsCheckedAndAWrongOneIsOverruled, testTheEstimatorOnlySeesTheScrollingRows,
testAfterAnUndoTheVoteAlignsWithoutTheEstimator, testUndoKeepsThePinnedBars,
testTheSizeLimitStopsAtThePixelBudget
ScreenshotCoordinatorTests: testScrollingCaptureReplacesTheFrozenOverlay,
testCancellingTheScreenshotStopsTheScrollingCaptureOnce,
testAScrollingFollowUpHandsTheLongImageOverWithoutTheEditor
MediaWorkerTests: testCopiedInputIsPrivateAndRemovedOnlyAfterConfirmedCollection,
testTwoRetainedChildrenBoundAdmissionAndShutdownFences,
testShutdownCancelsRunningChildAndRejectsNewWork
MediaProtocolTests: testInvalidIdentityVersionAndAmbiguousResponsesFailClosed,
testCommandFramesReadFailureAndSuccessfulResponse
```

`python3 -m unittest scripts.tests.test_media_packaging`: **2/2**, 0.339 s command wall time. A separate probe copied the actual helper into `Fixture.app/Contents/Helpers` using the packaging script, registered two identical synthetic patterned 200×200 RGBA frames, checked identity/translation and byte-preserved input: **passed**, 5.174 s including packaging and launch. No real desktop/window capture, wheel events, clipboard writes/paste events, app launches, microphone/TCC, network, provider or workflow effects. No layout changed and no screenshot was required; an actual synthetic panel order-out test verified lifetime behavior.

Tracked build/test/packaging/probe wall time: **553.093 s**. Audit, evidence copies, coverage extraction and review are additional. No full suite, Xcode app build, release signing/notarization or macOS 13/Intel hardware validation.

## Coverage provenance and limits

**267/271 changed executable lines = 98.52%.** The four uncovered lines are the new DI registration and three quit/shutdown bridges. `scroll-registration-coverage.json` records every changed production file. Session 101/101 and native decoder 27/27 line hits do **not** prove every branch, allocation failure, off-main deinit cleanup, watchdog expiration, real permission transition or actual quit/capture interaction.

All **seven fresh profiles** belong to the same final binary set: three host, three direct helper and one copied-helper probe. Each raw file was individually checked with `llvm-profdata show`, then merged without warnings. Earlier profiles were not reused. New source files were included with `git add -N`; extraction supplied the media helper as `llvm-cov --object`. No source or test inputs changed after the final build. Matching binaries/profiles are archived task-locally in `.build/scroll-validation/final`.

- XCTest SHA256: `7da366754a5f237d2ce33aac47d8041d0fef0d8de62c769f707fa3ea97ab51f2`
- Media helper SHA256: `27ecf75d5034f5c4c5f89ac0ad7a1632044e5d081cd405ee588b925036e18dde`
- Host undefined symbols contain no `VNTranslationalImageRegistrationRequest`. App and helper declare macOS 13.0 minimum; this is not hardware validation.

## Remaining approved work

Clipboard inline/audio playback and screen-recording preview still construct host AVPlayer instances. Explicit user-invoked OS Quick Look remains a separate OS/UI boundary. Existing file-index and semantic workers must not be duplicated. Further module adapters, condition-driven lifecycle and persisted health integration remain (registry currently three storage modules; media/native/inference domains are separate). Audio/TCC/signing/performance verification must precede choosing microphone capture isolation. Real CoreML/model performance, full Xcode packaging, Developer ID/notarization, macOS 13/Intel and real quit/recording remain unverified. Filesystem, JSON/base64, host rasterization/pasteboard/SQLite/UI/AppKit/GPU and system-memory failures are not contained by this increment. GUL-399 remains in progress; this is not whole-issue acceptance or arbitrary-crash/OOM/power-loss protection.
