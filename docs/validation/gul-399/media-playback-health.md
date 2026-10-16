# GUL-399: persistent media playback lifecycle and health

Stacked on #570, actual base `aad2e302b0d8732a08329eb2d61d861803668326` (`agent/arch-gpt-astra/gul-399-whisper-health`). Main remains `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`; its storage-only automatic quarantine reset, chat feedback and background-task changes are outside this tree and must be preserved on landing. Media/native/inference retain explicit persistent reset. No PR merge or CI wait.

## Behavior and ownership

`ClipboardPlaybackPool.shared` now starts closed until `PlaybackModule` binds it and the registry admits its generation. This is an independent `ModuleID.mediaPlayback` / `mediaPlayback.json`, covering the existing shared clipboard audio/video and recording-preview pool. It sits beside nine media extraction domains, native commands, Whisper inference and the unchanged three stores. No additional pool, helper, executable, full DI in a child, per-view supervisor or global test bypass.

The adapter reuses ModuleWorkerGate and the core supervisor. Its factory only checks executable availability off the UI actor and returns the same empty pool. It never loads media, probes native playback, polls a previous player or sends a control. Persistent recovery budget reserves once per factory generation, not per client, load, status poll or control. Existing bounded, content-free health persistence, corruption preservation, explicit reset and healthy-stop/stability semantics remain. Executable presence is not native/device/signing proof or a permission grant.

Entries capture the original generation. Admission and delivery fence immediately on faults; one coalescing observer triggers cleanup. Cleanup cancels owned clients and awaits one continuation until the same pool becomes empty. Cleanup expiry reports unavailable/degraded without replacing occupied capacity. Duplicate adapter binding fails closed and its release cannot stop the first owner. Adapter release cancels its own clients; attach-after-cancellation also stops immediately.

The original two-owner limit remains. Private input copies, pixel transport reservation and slots survive both actual child collection and all admitted host exchanges. An opening activity now also retains them until the asynchronous open returns, including a fast child exit during opening. MediaLease still owns child reaping and cleanup; ClipboardPlaybackRetirement owns host completion. Display images retain their separate existing pixel leases. Cancelled or uncooperative host work cannot create replacement capacity. Filesystem calls and cleanup can remain uncooperative; no total cleanup-latency or aggregate native-memory guarantee.

## Failure contract and controls

The bounded version-1 control envelope adds a payload-free `failed` terminal with the original UUID/sequence. Native load/control failures send it; malformed protocol or invalid promised state/frame still closes as a protocol failure. It carries no paths, diagnostic text or typed native reason. It can follow partial control effects: the caller receives `ClipboardPlaybackFailure.unconfirmed`, never a no-effect guarantee. There is no automatic control retry, resume or reload.

The parent validates failure framing/identity before treating it as a controlled job failure. Valid failure terminals do not label the whole pool a crash. Process nonzero exit, timeout, output truncation, malformed/missing response, wrong identity/sequence, mixed failure payload or incomplete pixels fault the pool. POSIX launch EACCES/EPERM/ENOENT/ENOEXEC waits for explicit capability recovery. Invalid local controls are rejected before sequence consumption/transport. Original source checks remain outside transport fault classification. Cancellation and revoked generations do not create new fault counts. Each failed entry reports at most once.

Self-review fixed an acknowledgement race: a clean process exit no longer immediately stops the host socket and discards an already-buffered failure reply. The active request can consume the terminal before retirement. Fault/configuration exits still stop transport. This is an additive paired app/helper contract, not a promise that an older helper implements the new failure kind; mismatched deployments fail closed.

ClipboardAudioPlayback retains its original scope/epoch/generation, one active operation, one pending control and failed attempt identity. Health recovery does not trigger its view task again. A new explicit scope/load may create a new client; an old client cannot inherit a new generation. Existing polling notices retired clients and clears presentation; it is not an instantaneous arbitrary callback rollback. Recording preview's explicit reload remains available for the retained original, without recapture/export. Existing panel hide/close/selection/deletion/account/token/owner retirement, slider identity, trim range, export stop, no-autoplay and source retention remain. Capture pause still permits history viewing. Encoding candidates, receipts and single authorized publication are untouched.

Audited PlaybackPool/Process/Retirement, AudioPlayback, inline audio/video views, recording coordinator/preview and their factories, server/AV engine/protocol/socket/helper entry, MediaLease/pixel ownership and DI/quit. The coordinator's native test fixture now injects an explicit pool; other mapped fixtures already inject clients/pools. No full DI was initialized for tests.

## Preserved bounds

Two owners; clipboard source 512 MiB and recording source 8 GiB, local resident regular final non-symlink files with original revision checks, private 0700 directories/0600 streamed copies and forbidden external AV references. One ordered 2 KiB JSON request/reply plus separately validated RGBA, maximum 1280 per axis / 1,048,576 pixels / 4 MiB. Existing native input geometry, stride/timestamp checks, display reservations and aspect/orientation behavior remain.

Parent load 10 s/control 5 s, child idle 10 s/independent 12 s alarm/send 2 s, four-hour lifetime and 100000 sequence cap remain. Playing video polls at 33 ms, paused/audio at 250 ms; no new queue. These are scheduling/contracts, not guaranteed frame rate, audible A/V latency or device performance. A sequence cap can end a long video before the lifetime cap; no auto-restart. Same two copies can consume 16 GiB for recordings, plus other domains and framework scratch. Source metadata snapshots are not immutable transactions. AppKit/AV/CoreAudio/CoreImage/GPU/system memory remain separate boundaries.

## Focused validation

**95/95 distinct methods passed in the initial functional pass (66 XCTest + 29 Swift Testing). Post-test self-review tightened semantic control-refusal classification, followed by a fresh build and all 22 affected methods passing (21 XCTest + 1 Swift Testing). There were no compilation or functional failures.** The final affected scope includes every new lifecycle method, all shared playback-isolation methods and the actual health UI. Other initial passing scopes were not rerun without a new dependency change.

- 9 new PlaybackModuleTests: closed defaults, once-per-generation budget, controlled load/control failure after possible effects, input/source/control refusals, nine process/protocol/pixel faults, four launch errnos, independent extraction domain, corrupt reset/missing helper, automatic and explicit recovery without replay, old generation, duplicate/owner release, opening/host/child/pixel retirement and two simultaneous managed native video/recording clients.
- 1 actual health settings test exercises Restore access without creating a client; five-language label and inspected 640×190 screenshot included.
- 12 ClipboardPlaybackIsolationTests, 9 ClipboardAudioPlaybackTests, 12 ClipboardVideoPlaybackTests, 10 RecordingPreviewIsolationTests and 9 ScreenRecordingCoordinatorTests cover existing controls, raw geometry, trim, original/export retention, actual hide/account/selection/deletion, late responses, gesture generation and uncooperative ownership. The existing native-failure server assertion now expects the explicit failed terminal.
- 13 MediaExtractionModuleTests, 12 registry, 6 health store, 1 storage compatibility and 1 localization parser method.

Two media packaging checks passed. An actually copied helper passed silent WAV load/seek/pause/status and malformed WAV failed-terminal probes; neither sends play. Native play/end/trim in mapped existing tests uses only verified no-audio synthetic video. The new managed native test loads/seeks two private no-audio video clients, rejects an out-of-duration playRange before native playback, then disables and rejects their old controls. Injected engines test audible-control branches without audio output. No real capture/microphone/TCC, user clipboard/paste/wheel, audio output, network/providers/external applications, real device/signing/full Xcode/full suite exercise.

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in XCTest and both helper binaries.
# Inventory through native_environment/native_tools + swiftpm-testing-helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:PlaybackModuleTests[./]|PlaybackHealthViewTests[./]|ClipboardPlaybackIsolationTests[./]|ClipboardAudioPlaybackTests[./]|ClipboardVideoPlaybackTests[./]|RecordingPreviewIsolationTests[./]|ScreenRecordingCoordinatorTests[./]|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))'
python3 -m unittest tests.test_media_packaging  # cwd: scripts
```

Builds 228.16 s, 30.63 s and 48.63 s passed (inner 224.37/30.32/48.31 s). The second added the managed native audio-free consumer fixture before functional testing. After the initial pass, self-review found that a structurally valid playRange beyond media duration throws invalidProtocol inside the native engine. That is a controlled operation refusal, not corrupt transport. The final change catches all engine-thrown failures while leaving request validation and returned state/pixel validation outside that catch. Added injected invalidProtocol refusal and real no-audio invalid-trim assertions; all 22 affected methods passed. No source/test input changed after the third build.

Inventories 3.841/4.798 s; test commands 36.51/17.19 s (initial XCTest 13.297 / Swift Testing 1.558 s; final XCTest 4.725 / Swift Testing 0.143 s). Initial packaging/probes 0.139/0.248 s; final packaging/probes 0.116/0.236 s. Tracked total **370.498 s**, excluding interpreter startup, audit/archive/extraction/inspection and platform/git actions. Existing unrelated compilation warnings remain.

Final affected command (same native environment and screenshot variables):

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:PlaybackModuleTests[./]|ClipboardPlaybackIsolationTests[./]|PlaybackHealthViewTests[./])'
```

## Coverage evidence and limits

Changed executable lines against actual PR base `aad2e302`: **154/156 = 98.72%**. Two DI composition bridge lines are unhit. Client/pool 116/116, adapter 25/25 and child server 13/13 changed lines hit; enum declarations add no counters. Guard-line hits do not prove both branches, native allocation failures, watchdog expiry, OS blocking behavior, audible synchronization or real quit.

Only **8 fresh profiles from the final correction binary**: three host, three direct media helper and two copied media helper. The initial 13 profiles and their matching binary are archived separately and excluded from final coverage; no counter layouts are mixed. Every raw validated separately, merge warning-free. Both media and unchanged inference helper included as llvm-cov --object; new Sources included with git add -N. Inventory excluded; no old profiles/layouts/results reused. Matching binaries/profiles and unchanged production hashes archived in `.build/playback-health-validation/final` (local evidence only).

- tests SHA-256: `ca8bccc9d39e6ad10e16a36b2c9b5464769ddd299af3d4f58ba29478a8466d97`
- helper SHA-256: `5ead3bd07eb5a8942f5f89f0ea93bb42288ac86b2e5ff03601c627f39bf35b46`
- media SHA-256: `57c51e187bbe82e2e2d30a67c5bddad177bce97b710f5ff0a0c627287f06f331`

App/helper retain minOS 13.0; this is not macOS 13 Intel hardware verification. File/semantic and other feature lifecycle adapters, broader condition integration, remaining native/media audit, audio/TCC/signing/performance before microphone capture ownership, real model/device/full Xcode/Developer ID/notarization/actual quit remain. Capture/live audio meter and user-invoked OS QuickLook are separate boundaries. No arbitrary host/native crash, systemwide OOM or power-loss guarantee. GUL-399 remains in progress.
