# GUL-399: recording encoding lifecycle health

Base: open draft #566, `acae891ee060554c62500944a6fe6b5ba9ea1364`, branch `agent/arch-gpt-astra/gul-399-timeline-health`. This increment stacks on #566–#561; earlier work through #560 is on main. Main at validation is `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`. Its storage-only persistent quarantine auto-recovery (default policy false, StorageModules opt-in), persistent chat feedback and background-task window changes are not in this tested feature tree. Preserve them during integration; media retains explicit persistent reset. No GitHub merge or prior closure audit repeated.

## Behavior and audit

`MediaWorker.recordingExport` now requires lifecycle readiness. The existing closed Domain/ModuleID composition retains nine independent media adapters plus the unchanged three stores. `recordingExport.json` reserves once per factory generation, never per encoding request/progress event. Five localized labels expose the existing settings recovery control. No new pool, executable, protocol, helper, packaging target or DI machinery. Readiness checks executable availability, not signing/native codec support.

Audited encoder/exporter, canonical session ownership and deferred discard, publication prepare/single commit, coordinator export/account/window/quit, MediaWorker.owned/MediaLease/generation gate, helper decoder/entrypoint and standalone defaults. Unlike perform-based extraction, encoding has a custom streaming producer. Merely binding its pool would miss failures, so the owning operation now classifies its runner and promised-output boundary explicitly.

A clean exit with a complete, structurally valid `failed` terminal is a controlled job failure, not evidence of a subsystem crash. The existing protocol has no typed failure reason; this category includes rejected input/native encode or filesystem failure reported by the child. It still returns caller-facing unconfirmed failure and retains remaining files. No failure is converted to successful output. Process timeout/nonzero exit, runner failure, malformed/truncated/trailing stream, missing terminal and inconsistent promised output fence the current generation. Launch POSIX EACCES/EPERM/ENOENT/ENOEXEC waits for explicit recovery. Original-source changes, destination collision, retention quota and host permission application remain separate host/input failures. The runner is a transport seam; errors thrown from it are infrastructure failures, unlike pre/post source checks.

Successful output validation retains fixed-path, no-follow regular single-link, exact length and signature checks without host native reparse. A child claiming success with missing/wrong-type/wrong-size/bad-signature output is a protocol fault even if its existing error type is unreadable. A local fchmod failure is unavailable rather than blamed on the decoder. Cancellation or generation revocation suppresses fault counting and late output. Health recovery never stores or replays an encoder call, capture, publication, copy or other action.

Unknown/failed/cancelled attempts retain original, private input, request UUID and remaining partial output. Generic lease directory cleanup remains enabled ONLY after a known validated exclusive candidate transfer. Existing single authorized publication and UUID receipts are unchanged. No rollback, zero-effect, automatic reconciliation or durable retry claim. Frameworks may remove their own failed temporary files; only remaining files can be retained.

Existing budgets remain: two host admissions and two 600-second children, 605-second helper alarm and two-second shutdown wait; one canonical source-session owner; four retained attempts/session and 1,024-entry scan; 8 GiB input/MP4 output; GIF 50,000,000 bytes/301 frames; existing native geometry/audio/trim/frame bounds. Progress remains sequenced, finite and monotonic with 1 KiB events, 604-event/256 KiB total limits. Private copies, occupied slots and session ownership survive BOTH host completion and actual child reaping. No occupied pool replacement or expanded capacity. Filesystem/copy work can block outside child deadline; snapshots are not immutable transactions. Retained attempts can consume 64 GiB/session plus originals/other copies/scratch; no global quota, eviction or fsync guarantee.

Production defaults fail closed before DI. Existing exporter memberwise encoder injection suffices: the synthetic native compatibility fixture and two opt-in capture fixtures now explicitly inject standalone workers. The two capture fixtures were compiled but NOT executed. No full DI/global mutable bypass. Composition tests verify all nine fixed identities/workers. Existing trim/orientation/mixed-audio/GIF/progress behavior and feature-owned account/window/source authorization remain unchanged.

## Validation

**88/88 distinct focused methods passed in one functional pass: 58 XCTest and 30 Swift Testing.** No compile or functional failures/retries. No full suite.

| Scope | Methods | Evidence |
| --- | ---: | --- |
| RecordingExportModuleTests | 10 | pre-DI refusal; valid failed-terminal retention and per-generation budget; ten process/output fault variants; four launch configuration errors and independent timeline; corrupt record/clock/reset; source/destination/quota refusals; uncooperative host and delayed child capacity; old generation; real managed MP4/GIF and controlled native refusal; single publication; actual panel/account cancellation and no copy/replay |
| RecordingExportHealthViewTests | 1 | actual localized settings row and AX recovery button without producer execution; screenshot inspected |
| RecordingEncodingIsolationTests | 11 | native trim/orientation/GIF/bounds, progress framing, output identity, partial/missing acknowledgement, source ownership, cancellation/reaping/deferred discard |
| RecordingPublicationIsolationTests | 13 | authorized single commit, retained unknown effects, source/stage/destination identities, bounds, duplicates and privacy |
| ScreenRecordingCoordinatorTests | 9 | explicit lifecycle/cancellation/export outcomes with injected capture and silent synthetic playback |
| ScreenRecordingMediaTests | 1 | real synthetic MP4 mixed audio encoding and trimmed GIF; no audio playback |
| MediaExtractionModuleTests / MediaWorkerTests | 13 / 9 | shared faults/conditions/generation/retirement/persistence, harmless child crash/hang and quit |
| ModuleRegistryTests / ModuleHealthStoreTests / StorageModuleRegistryTests | 12 / 6 / 1 | lifecycle, bounded persistent clock/corruption/quarantine and unchanged storage behavior |
| ClipboardThumbnailModuleTests / LocalizationResourceTests | 1 / 1 | nine-domain composition and five localization tables |

Commands use scripts/test_runtime.child_environment:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <regex below>
python3 -m unittest scripts.tests.test_media_packaging
```

```text
^Typeflux(?:Focused)?Tests[./](?:RecordingExportModuleTests[./]|RecordingExportHealthViewTests[./]|RecordingEncodingIsolationTests[./]|RecordingPublicationIsolationTests[./]|ScreenRecordingCoordinatorTests[./]|ScreenRecordingMediaTests[./]`real MP 4 mixes both audio tracks and GIF honors trim`(?:\(|$)|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./]|ClipboardThumbnailModuleTests[./]testProductionCompositionMapsEveryIndependentPoolWithoutStartingRequests(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))
```

Self-review preceded functional tests. Three preparation builds passed: **123.14 / 47.17 / 62.48 s** (inner **119.80 / 46.89 / 62.18 s**). The second changed only a new fixture's unsafe array access to a reporting unwrap; the third explicitly initializes NSApplication before the new actual-panel fixture. Both corrections were made before any functional test, after the preceding build exited. Production unchanged after first build. Existing unrelated warnings remain. No source/test input changed after the final build.

Prebuilt inventory used native_environment/native_tools plus swiftpm-testing-helper, **3.877 s**, matched 88 methods, no discovery rebuild. Host/helper __llvm_covmap and __llvm_prf_cnts verified before tests. Focused command **38.09 s** (XCTest **10.260 s**, Swift Testing **2.561 s**). **2/2 packaging checks**, reported **0.128 s**. No copied-helper probe because helper/protocol/packaging unchanged; actual managed synthetic MP4/GIF/refusal and existing harmless process-fault children exercised. Tracked total **274.885 s**, excluding packaging interpreter startup, audit/archive/extraction and screenshot inspection.

Actual 640×190 unavailable recording-encoding health row inspected: title, status, restore button and previous-actions-will-not-run explanation visible. Synthetic audio tracks were encoded only. Any existing playback fixture is a verified no-audio movie. No user clipboard/paste/wheel, real capture/microphone/TCC, audio output, network/provider/app launch, full Xcode, signing or hardware exercise. All jobs/children collected.

## Coverage and remaining boundaries

Against actual base acae891e, **27/27 changed executable lines = 100%**: 25 encoder classification/validation lines and two closed-domain mappings. Enum/static declarations have no added counters. This small denominator is not every-branch/native-allocation/watchdog/device/real-quit proof. In particular a hit on the fchmod guard does not prove its failure branch, and the valid failed terminal does not identify every native cause.

ONLY **16 fresh profiles (3 host, 13 direct helper)** from ONE final binary, every raw individually validated and warning-free merged, helper included with llvm-cov --object. No old results/profiles or counter-layout mixing. No new Sources require git add -N. Inventory-only profile excluded; production hashes verified unchanged. Evidence `.build/encoding-health-validation/final`.

- XCTest SHA-256: `bf70ccf362ffc1ff20e1a121e28e52f62ead5dd8f96051c9cef6146306a5e81b`
- Unchanged helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`
- App/helper minimum OS 13.0 does not establish macOS13/Intel hardware support.

All nine existing MediaWorker domains now have independent lifecycle health, but native-system, inference, playback and feature adapters and broader condition-driven lifecycle remain. Next is a separately audited native-system command adapter: no command/toggle/probe replay as a readiness action, truthful unknown execution, retained host/child ownership. Storage auto-reset remains opt-in only for stores when main is integrated.

Remaining native/media audit and audio/TCC/signing/performance verification precede microphone capture ownership decisions. File processing does not decide live capture. Host filesystem/JSON/base64/raw raster/pasteboard/SQLite/import-export/UI, live capture/audio meter and AppKit/GPU/system memory remain boundaries. User-requested OS Quick Look is a distinct OS/UI boundary; existing file/semantic workers are not duplicated. Real CoreML/full Xcode/Developer ID/notarization/macOS13/Intel/actual quit-recording remain unverified. No arbitrary host crash, system-wide OOM or power-loss guarantee. GUL-399 remains in_progress.
