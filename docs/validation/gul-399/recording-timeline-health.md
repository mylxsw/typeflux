# GUL-399: recording timeline and poster lifecycle health

Base: open draft #565, `fb67115f9347eea63e69d944bac68ed36dcfe99b`, branch `agent/arch-gpt-astra/gul-399-metadata-health`. This increment is stacked on #565/#564/#563/#562/#561; earlier work through #560 is on main. Main at delivery is `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`. Its storage-only quarantine auto-recovery (default policy false, StorageModules opt-in), persistent chat feedback and background-task window changes are not in this tested feature tree. Preserve them on integration; no media opt-in to storage's automatic persistent reset. No GitHub PR merge or old closure audit repeated.

## Behavior and audit

`MediaWorker.recordingTimeline` now requires lifecycle readiness. Existing closed Domain/ModuleID mapping adds independent `recordingTimeline.json`, retaining eight media adapters alongside the unchanged three stores. Five localized labels expose the existing settings recovery control. No new helper, protocol, process pool, DI machinery or global test bypass. Factory readiness checks executable availability, not signing or native format support.

Reservations remain once per factory generation, not per batch, poster, frame or file action. Typed requests still use the original two-child/30-second pool and 35-second helper alarm. The two host preparations, owned private copies, retained pixel reservations and actual host-completion AND child-reaping barriers remain; recovery cannot replace an occupied pool or expand capacity. Display CGDataProvider leases outlive the request. Health persistence stays content-free, bounded and off UI, preserving corrupt records until explicit reset.

Audited ScreenRecordingTimelineLoader, ScreenRecordingPreviewMedia, coordinator mediaTask/source/epoch/visibility retirement, toast model/controller/view and explicit controls, DI/quit, all direct loader/default fixtures. Existing worker/closure seams suffice except one narrow optional loader argument on PreviewMedia.load for the standalone recovery fixture. Production defaults remain closed before DI readiness. Composition tests verify all eight exact IDs/workers without starting full DI.

Timeline and GIF/video poster operations share this domain. Original contracts remain: recording inputs up to 8 GiB; GIF up to 50,000,000 bytes and 301 frames; local/resident/regular final nonsymlink files and pre/post revision checks; one private copy per request; ten oriented 200×120 raw thumbnails; whole-recording 160-bucket peak waveform across all audio tracks; existing finite metadata/fps, PCM chunk/total/scan budgets; absent audio distinct from unavailable. This does not substitute clipboard's 600-second/180-bucket or Ask's 30-second/80-bucket waveform.

`inspect` shares the two host preparation slots but performs only bounded file identity checks, not native parsing. It deliberately remains independent of decoder readiness. Validated supplied thumbnails retain their original pixel lease and need no new decode; unavailable posters preserve fallback/file controls while source validation still succeeds. Explicit actions recheck source/presentation identity immediately before their injected callback. Recovery never automatically reveals, copies, discards, plays, recaptures, re-records or exports.

The coordinator/task and toast scopes retain original account/window/source/generation authority. Actual hide/close/miniaturize, account change, replacement and owner release withdraw private outputs. Ready health cannot bless an old scope or trigger an old view request. Timeline failure preserves original recording and the existing export entry when playback supplies valid duration; encoding candidates and publication receipts are untouched.

Fault audit: typed input refusals remain expected, invalid successful envelopes and missing/wrong-size/type/link raw files remain protocol faults. Shared raw-file reading now also converts a FileHandle read failure into invalidProtocol: the child promised an exact readable output. Host CGImage provider/allocation failure remains a local unavailable result, not a claim of child crash. No blanket classification of arbitrary extraction callbacks. Source revision failures outside the worker remain source failures. Filesystem work can block outside the child deadline; snapshots are not immutable transactions.

## Validation

**86/86 distinct focused methods passed in one pass: 56 XCTest and 30 Swift Testing.** No compilation or functional failure/retry. No full suite.

| Scope | Methods | Evidence |
| --- | ---: | --- |
| RecordingTimelineModuleTests | 8 | pre-DI fail-closed with inspection available; independent metadata/timeline budgets; corruption/clock/reset; reaped-child/uncooperative-host capacity; typed refusals vs invalid raw success for all three operations; real managed batch/video/GIF geometry and display lease; unavailable poster/supplied pixels/explicit actions without replay; actual hide/account/replacement/owner release fences late output |
| RecordingTimelineHealthViewTests | 1 | actual settings row and AX recovery button without file execution; screenshot inspected |
| RecordingTimelineIsolationTests | 10 | native batch/all-track waveform, orientation/order, limits, source mutation, pixel leases, cancellation, coordinator late output and export retention |
| RecordingToastIsolationTests | 12 | native GIF/video posters, input/raw bounds, cancellation, file identity/actions, replacement/account/hide/owner lifetime and actual component |
| ScreenRecordingCoordinatorTests | 9 | explicit lifecycle/cancellation/export outcomes using injected capture/export and silent fixture playback |
| ScreenRecordingRedesignTests | 1 | changed recovery metadata injection, original options/source retention |
| MediaPreviewTests | 2 | shared reader missing/truncated/symlink/directory/oversized rejection and pixels surviving private-file cleanup |
| MediaExtractionModuleTests | 13 | shared readiness/fault/generation/conditions/persistence/retirement behavior |
| MediaWorkerTests | 9 | protocol/bounds, cancellation, crashes/hangs, ownership and quit |
| ModuleRegistryTests / ModuleHealthStoreTests / StorageModuleRegistryTests | 12 / 6 / 1 | lifecycle graph, persistent clock/corruption/quarantine and unchanged storage composition |
| ClipboardThumbnailModuleTests / LocalizationResourceTests | 1 / 1 | eight exact domain mappings; five string tables parse |

Commands use scripts/test_runtime.child_environment:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <regex below>
python3 -m unittest scripts.tests.test_media_packaging
```

```text
^Typeflux(?:Focused)?Tests[./](?:RecordingTimelineModuleTests[./]|RecordingTimelineHealthViewTests[./]|RecordingTimelineIsolationTests[./]|RecordingToastIsolationTests[./]|ScreenRecordingCoordinatorTests[./]|ScreenRecordingRedesignTests[./]`recovery loads original options and deleting only affects owned sessions`(?:\(|$)|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./]|MediaPreviewTests[./](?:testHostRejectsMissingTruncatedSymlinkDirectoryAndOversizedRasterFiles|testHostValidatesPixelsAndOwnsCopiedRasterAfterCleanup)(?:\(|$)|ClipboardThumbnailModuleTests[./]testProductionCompositionMapsEveryIndependentPoolWithoutStartingRequests(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))
```

Prebuilt inventory used native_environment/native_tools + swiftpm-testing-helper, with no discovery rebuild or direct execution of xctest. Both TYPEFLUX_ASK_SNAPSHOTS and TYPEFLUX_GUL303_SNAPSHOTS were enabled. LLVM covmap/counter sections verified before tests. No source/test inputs changed after the build.

- Build **114.12 s** (inner 110.98 s), passed; existing unrelated warnings remain.
- Prebuilt inventory **3.924 s**, matched 86 methods.
- Focused command **37.25 s** (XCTest 10.438 s, Swift Testing 2.440 s), passed.
- **2/2 packaging checks**, reported **0.147 s**. No copied-helper probe: helper/protocol/packaging unchanged. Real managed synthetic timeline/poster and existing harmless fault children ran.
- Tracked total **155.441 s**, excluding packaging interpreter startup, audit, archive/extraction and screenshot inspection. One log-read command used the repository cwd instead of workspace and was corrected; it did not repeat tests.

Actual 640×190 health row screenshot inspected: service name, unavailable status, restore button and no-replay explanation visible. Synthetic movies used for playback have no audio track; synthetic audio tracks were analyzed only. No real user clipboard, paste/wheel events, capture/microphone/TCC, audio output, network/provider/app launch, full Xcode, signing or hardware exercise. All jobs and children collected.

## Coverage and limits

Against actual base fb67115f, **6/6 added executable lines = 100%**: two domain branches, two loader forwarding/declaration lines and two raw-reader lines (including comment attribution). Enum/static declarations have no added line counters. This small denominator does not prove every native branch, arbitrary I/O errno, allocation failure, watchdog, language/format/device behavior or real app quit.

ONLY **20 fresh profiles (3 host, 17 direct helper)** from ONE final binary. Every raw profile individually validated, warning-free merge, helper included with llvm-cov --object. No new Sources need git add -N. Inventory-only profile excluded. No old profiles/results or mixed counter layouts. Production source hashes verified unchanged. Evidence: .build/timeline-health-validation/final.

- XCTest SHA-256: `6ac380907afc7a7e4f7af17c5a47a5fbbe7e68581039aaec17b1f73817719199`
- Unchanged helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`
- App/helper minimum OS 13.0 is not macOS13/Intel hardware validation.

Recording encoding's custom owned stream and unknown outputs still need their own health classification and adapter; never blindly bind it as if perform covered it. Native/inference/playback/feature adapters and broader condition-driven lifecycle remain. Preserve retained candidates/receipts and single authorized publication; no write/toggle/count/Agent/workflow/system-command/paid-generation/shutdown replay or database deletion/recreation.

Remaining native/media audit and audio/TCC/signing/performance verification precede microphone capture ownership decisions. File processing does not decide capture. Live capture/audio meter, host filesystem/raw raster/JSON/base64/pasteboard/SQLite/import-export/UI and AppKit/GPU/system memory remain boundaries. User-requested OS Quick Look is an OS/UI boundary; existing file/semantic workers are not duplicated. Real CoreML/full Xcode/Developer ID/notarization/macOS13/Intel/actual quit-recording remain unverified. No arbitrary host crash, system-wide OOM or power-loss guarantee. GUL-399 remains in_progress.
