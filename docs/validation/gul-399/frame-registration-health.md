# GUL-399: scrolling frame registration lifecycle and persistent health

Base: open draft #561, `0f65c8e0ede7e99c0e99baeb300711e869d6598d`, branch `agent/arch-gpt-astra/gul-399-clipboard-health`. This is a stacked increment, not another main integration. #559/#560 and earlier work are already on main. At audit main was `c49be72f4cca891d6ef9b2213a56527d03ceb299`; its new one-shot persistent quarantine recovery is explicitly enabled by StorageModules, with the policy default false. That concurrent change is not in this tested feature tree. Read-only merge-tree against main succeeded; no merge or CI wait was performed, and parent PR bases were preserved.

## Behavior

`MediaWorker.frameRegistration` now requires lifecycle readiness. The existing closed domain mapping binds it to independent `ModuleID.frameRegistration` and `frameRegistration.json`. `MediaExtractionModules` retains four managed media adapters; the existing DI composition and registry start/disable/quit paths pick up this fourth domain. Five localizations expose the existing settings health/recovery row. No new helper, protocol, executable, pool, generic request wrapper or full-DI test initialization.

Persistent reservations remain once per factory generation, not per frame. Existing bounded content-free health records, explicit corruption/quarantine reset, coalesced observation, generation fence, recovery budget and fault classification are reused. Expected malformed source/input/permission/configuration refusals do not become a native process crash. Response identity/framing/invalid shifts, child exit and deadlines fault the registration domain. Recovery restores capability only: no frame, capture, wheel event, final drain or export is saved for replay.

The same two-child/three-second registration pool retains both host completion and actual child collection before capacity can reopen. Existing two preparation admissions, 16-million-pixel/16384-axis per-frame and 128 MiB pair transport limits remain. Raw host rasterization occurs before `perform` admission and remains bounded by the estimator's preparation slots; lifecycle readiness does not claim to eliminate that host work. Cleanup timeout cannot replace the occupied pool or expand capacity. Executable readiness is not native-format/signing/device proof.

Audited `VisionScrollOffsetEstimator`, `ScrollFrameRegistering`, both stitchers, `ScrollCaptureSession` real-time analysis and asynchronous final drain, and the ScreenshotCoordinator production factory. Native proposals still provide both signs; row/hash/pinned-bar validation decides alignment. Registration unavailability drops only that candidate source. Axis selection, undo/version fences, account/panel/owner cancellation, latest-frame inbox and one-shot finish remain unchanged. No blocking IPC in getters or UI-actor final drain was introduced.

Standalone session fixtures already inject estimators. The one old native estimator fixture now explicitly injects a worker; no global test bypass. The composition fixture now verifies all four exact worker/ID mappings. A new session fixture uses injected frame source, driver, presenter and process runner to prove disable/re-enable does not capture, scroll or finish again, including explicit final pending-frame drain. Original frame data and capture ownership are unchanged.

## Validation

One build and one focused functional pass after implementation/self-review. **110/110 distinct methods passed** (90 XCTest + 20 Swift Testing), no compilation/functional failures or retries. No source/test inputs changed after the final build.

| Scope | Methods | Validation |
| --- | ---: | --- |
| FrameRegistrationModuleTests | 6 | pre-DI rejection + checked fallback, independent budget, corrupt record/clock/reset, expected refusal vs invalid shift, cancelled uncooperative host capacity, real managed native candidates with both axes/undo/recovery |
| FrameRegistrationHealthViewTests | 1 | actual localized health row, actual recovery button without decoder invocation, screenshot |
| ScrollCaptureSessionTests | 36 | new managed recovery/no-replay case; existing final drain, undo, account/owner, source stop, pause and injected scroll behavior |
| ScrollRegistrationIsolationTests | 9 | protocol/shape/overflow, real native registration, fallback/axis checks, cancellation, crash/hang, panel/inbox |
| DirectionalScrollStitcherTests | 6 | orientation/axis/pinned behavior |
| ScrollStitcherTests | 11 | exact overlap, pinned bars, row/hash validation, bad proposals, undo and pixel limits |
| VisionScrollOffsetEstimatorTests | 2 | signs and changed explicit real-worker fixture |
| ScreenshotCoordinatorTests | 3 | injected scrolling lifecycle and follow-up handoff |
| MediaExtractionModuleTests | 13 | shared supervisor/admission, condition/readiness, old generation, retirement and quit |
| ModuleRegistryTests | 12 | dependency ordering, condition changes and bounded old work |
| ModuleHealthStoreTests | 6 | bounded persistence, corrupt/quarantined state, simulated clock, failure/reset |
| StorageModuleRegistryTests | 1 | unchanged storage composition compatibility |
| MediaWorkerTests | 2 | unreaped capacity and shutdown |
| ClipboardThumbnailModuleTests | 1 | changed four-pool production mapping/composition |
| LocalizationResourceTests | 1 | five string tables parse |

Commands use `scripts/test_runtime.child_environment`:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <regex below>
python3 -m unittest scripts.tests.test_media_packaging
```

```text
^Typeflux(?:Focused)?Tests[./](?:FrameRegistrationModuleTests[./]|FrameRegistrationHealthViewTests[./]|ScrollRegistrationIsolationTests[./]|ScrollCaptureSessionTests[./]|DirectionalScrollStitcherTests[./]|ScrollStitcherTests[./](?:testFramesJoinIntoTheExactPage|testPinnedHeaderAndBottomBarAppearOnce|testABlurredBandUnderThePinnedHeaderJoinsIt|testStickyLinesAtTheTopStillLetLaterFramesLineUp|testRedrawnContentStillLinesUp|testARepeatingLayoutDoesNotFoolTheAlignment|testTheEstimatorsShiftIsCheckedAndAWrongOneIsOverruled|testTheEstimatorOnlySeesTheScrollingRows|testAfterAnUndoTheVoteAlignsWithoutTheEstimator|testUndoKeepsThePinnedBars|testTheSizeLimitStopsAtThePixelBudget)(?:\(|$)|VisionScrollOffsetEstimatorTests[./]|ScreenshotCoordinatorTests[./](?:testScrollingCaptureReplacesTheFrozenOverlay|testCancellingTheScreenshotStopsTheScrollingCaptureOnce|testAScrollingFollowUpHandsTheLongImageOverWithoutTheEditor)(?:\(|$)|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./](?:testTwoRetainedChildrenBoundAdmissionAndShutdownFences|testShutdownCancelsRunningChildAndRejectsNewWork)(?:\(|$)|ClipboardThumbnailModuleTests[./]testProductionCompositionMapsEveryIndependentPoolWithoutStartingRequests(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))
```

- Build **99.71 s** (inner build 95.90 s); prebuilt native inventory **4.339 s**, 110 matches. No discovery rebuild/direct xctest execution.
- Test command **62.69 s** wall time; XCTest 38.468 s, Swift Testing 0.510 s.
- **2/2 packaging checks passed**, unittest reported **0.153 s**. No new copied-helper probe because helper/protocol/packaging are unchanged; real synthetic registration and existing native fault paths ran in the scope.
- Tracked durations total **166.892 s**, excluding packaging interpreter startup, audit, archive/coverage and screenshot inspection. Existing unrelated compiler warnings remain.

Actual `frame-registration-health.png` 640×190 unavailable row inspected. Both snapshot environment variables were enabled. No full suite, real capture/TCC, wheel/paste/user clipboard, audio output, network/provider/external app, signing/full Xcode/hardware exercise. Frame sources, wheel drivers and side effects were injected; native registration used private synthetic pixels. All jobs collected, no XCTest/helper child remained.

## Coverage and limits

Against the actual parent: **2/2 added executable lines = 100%**. This very small denominator consists of the two new domain mapping branches; enum/static declarations have no added line counters. It is not whole-feature, branch, native allocation, real capture/quit or watchdog coverage. The focused behavior tests above are the evidence for the reused machinery.

Only **12 fresh profiles** (3 host + 9 direct-helper) from ONE final binary set were individually checked before a warning-free merge. No prior increment results/profiles/layouts reused. `__llvm_covmap`/`__llvm_prf_cnts` verified; llvm-cov includes helper as `--object`, with no changed helper line claim. Inventory-only root `default.profraw` was excluded/archived separately. Production hashes match the archived build. Matching local evidence `.build/registration-health-validation/final`:

- XCTest SHA-256: `51b7203d54e4828d7f6e2b53cdb5ede57478bc816a05169208a74f30ad82d644`
- Helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`

Remaining unmanaged media pools include shared text recognition/clipboard OCR, clipboard metadata/recording timeline and recording encoding. Custom owned encoding streams and retained unknown outputs must not be blindly treated as covered by `perform`. Native/inference/playback/feature adapters, broader lifecycle conditions, remaining native/media audit and audio/TCC/signing/performance verification before capture ownership remain. No duplicate file-index/semantic decoder worker. Explicit OS Quick Look remains an OS/UI boundary.

Host filesystem/raw raster/JSON/base64/pasteboard/SQLite/import-export/UI and AppKit/GPU/system memory remain boundaries. No arbitrary host crash, system-wide OOM or power-loss guarantee. Storage/user databases, recording candidates/receipts and single authorized publication are unchanged. No automatic write/producer/workflow/paid-generation/shutdown replay. Real CoreML/full Xcode/Developer ID/notarization/macOS13/Intel/actual quit-recording remain unverified. GUL-399 remains in_progress and is not ready for overall acceptance.
