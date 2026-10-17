# Recording startup and file-writer queue bounds

Validated baseline: `f8b726d96b41f2231298fd142c198d9fbdb8bdb8`, read immediately after creating the clean branch from fetched main. This binary includes #636's source/test layout; that unrelated audio-window behavior was compiled, not functionally tested. This completes the two already-confirmed host audio resource queues in the fixed acceptance list. It does not migrate microphone ownership or pass signed-device gates.

## Result and contracts

`RecordingStartupAudioBufferRelay` now bounds its pre-activation prefix to 4,096 buffers / 32 MiB total, with a 256 KiB per-buffer admission check before copying. Instance limits can reduce, not increase, these caps. Copies allocate frame length rather than the producer's potentially much larger frame capacity. The existing configured duration tail is trimmed before reserving the copy; instant 0.5-second pre-roll and composer 30-second policies remain. Count/byte overflow or invalid input latches a failure and discards the incomplete prefix. Activation returns that error and never delivers a truncated successful prefix. Only explicit stale-pre-roll discard resets the failure. First arrival timing, ordering and the active zero-copy path remain.

The recorder consumes activation failure into the original write attempt. Workflow/composer consumers mark the existing realtime pump failed, so its normal finish/error policy handles missing input; live preview is canceled on failed activation. There is no recording restart, new provider retry policy or paid producer replay. The recording file remains the original file.

`AudioBufferWriteCoordinator` now reserves capacity before conversion, preview copy or asynchronous dispatch: at most 64 preparations/queued/in-flight operations and 16 MiB, with 256 KiB per reservation. Production reserves both converted and preview allocations using the same pure output-capacity bound that conversion checks before creating its native converter/output buffer. Raw input also has a bounded validity check. These are application queue/allocation budgets, not a bound on framework scratch memory, upstream tap allocations or the entire heap.

Every recording owns a concrete attempt identity and first-error receipt. Overflow, conversion or writer failure stops subsequent admissions/queued effects for that attempt. Reservations are released on actual writer return (or abandoned preparation), never by cancel, new attempt or UI timeout. `drain` includes preparation reservations and physical writes. Retained reservation handles do not keep completed operations artificially occupied. A replacement cancels the old attempt without resetting shared occupancy; old failure cannot poison the replacement. A submitted reservation writes at most once. Already-entered writes may have changed the file/sink and cannot be rolled back or retried.

After the existing tap/callback/writer collection and recorder cleanup, `stop` throws `IncompleteAudioRecording` with the original `AudioFile` and cause when input/file writing failed. It does not return truncated success or delete the partial file. The workflow failure history retains that file path; composer marks the already-stopped incomplete recording retired and propagates the receipt before its successful-file deletion path. Unknown native stop failures are not reclassified as completed cleanup. Full recorder/workflow bridges were compiled and audited, not object-tested.

No new worker, helper ABI, pool, generic dispatcher, DI/global bypass, microphone owner or automatic side-effect replay was added. Existing native stop/removeTap/reset exception boundaries were not broadened or caught-and-ignored. Source/account/permission consent and real device retirement retain their earlier limits.

## Focused validation

**29/29 distinct methods passed on the first functional pass:** 16 XCTest methods in two suites (0.021 seconds; selected suite wall 0.024 seconds) and 13 Swift Testing methods / 14 parameter cases (0.016 seconds). No failed test, fixture correction, timeout relaxation or functional retry. All gates, reservations, queue writers and pump tasks were released/collected. The exact inventory and exclusions are in `recording-queue-bounds-methods.json`.

- Nine new `RecordingQueueBoundsTests` methods exercise before-copy bounds, frame-length copies/active zero-copy, truthful relay failure/reopen, configured tail order, reservation bounds before preparation, replacement/cancellation retaining physical occupancy, one entered sink effect, no duplicate submit, first failure/queued refusal, old failure versus fresh attempt, pure allocation guards and incomplete file/realtime failure receipts.
- Six existing raw-buffer relay regressions and the ordered multi-operation coordinator test preserve timing, cancellation, prefix/tail behavior and serial order. The timer-based coordinator test was not needed or selected.
- Thirteen `RealtimeAudioBoundsTests` regress the direct shared pump/encoded queue contracts and owned zero-based Data reset/flush behavior from #637. All bodies and called helpers were read before selection.

Fixtures use only raw AVAudioPCMBuffer/Data, AVAudioFormat metadata, pure production relay/coordinator/converter preflight and fake write/transport sinks. The converter object stores target-format metadata; no AVAudioConverter is constructed or called. No recorder, AVAudioEngine, actual device/input/output, AVAudioFile write, codec, provider/model/network, clipboard (including named), home/apps/windows, TCC, signing or full suite ran. No global scheduler freeze or exhaustive interleaving claim. Semaphores gate only owned writer callbacks; every gate has a cleanup release/drain. No timers are used for ownership evidence (a five-second entry timeout only bounds a failed test wait).

## Coverage and build provenance

Changed executable lines versus the actual baseline: **142/187 = 75.94%**, meeting the human's current **70%** threshold. No extra tests or rebuilds were performed to pursue 80/90%. The denominator retains recorder/native converter/workflow bridges excluded from execution.

| Source | Hit / changed executable |
| --- | --- |
| AVFoundationAudioRecorder (relay plus unhit recorder bridge) | 36 / 62 |
| AudioRecordingBufferConverter (pure bound plus unhit native conversion bridge) | 16 / 21 |
| AudioRecordingQueue | 86 / 86 |
| RealtimeTranscriptionSession | 4 / 4 |
| WorkflowComposerRecording | 0 / 6 |
| WorkflowController+Processing | 0 / 3 |
| WorkflowController | 0 / 5 |

One native build (`--build-tests --enable-code-coverage --jobs 4`) passed: 457.09 seconds command wall / 442.08 compiler-reported. Inventory 6.198 seconds; focused skip-build/no-parallel coverage run 31.17 seconds; archive 23.853 seconds. Core build+inventory+test wall 494.458 seconds, with archive 518.311 seconds, excluding evidence extraction/audit/platform delivery. No Source/Test inputs changed after the build. No new changed-line/new-test warning. The prior redundant Void-result warning in unchanged PCM16FrameChunker copy code remains, along with unrelated warnings and native-build deprecation; the whole build is not warning-free.

Three fresh HOST profiles from one test/app binary: XCTest discovery, XCTest execution and Swift Testing execution. Every raw profile validated; sparse merge and independent remerge were warning-free and byte-identical. Matching app object used for show/export, with empty stderr; both binaries contain LLVM coverage mapping and counters. All-function inspection stderr was empty. The 545 reported Swift function hashes are zero; this is not layout proof. Explicit source/test/binary/profile hashes establish the layout used here.

All **2,032 Swift inputs (1,157 Sources + 875 Tests)** match PREBUILD, live and archive after extraction. Original/copied raw hashes and live/archived binaries match. Old live/root-default profiles and the separately excluded inventory root profile are not merged; no mixed-layout or child coverage claim. Every build/inventory/test/archive/extraction was collected before the dependent step.

- Test SHA-256: `5076cebbea6bb5694e3ae9b3dea19a72031683d43cb61d03635be2527d4d5c97`
- App SHA-256: `8333c46a75ca3546c4e2f0ccada781ce00e795922ade737f407656f15f61a6d6`
- Private evidence: `.build/recording-queue-bounds-validation/final`; public method/coverage JSON accompany this report.

No layout/presentation or helper entry/ABI/package change occurred, so no screenshot or copied helper probe was applicable. This is focused resource/attempt evidence, not all branches/races/errno/devices/runtime DI, arbitrary native crash/OOM/power-loss containment or a filesystem/account/permission transaction.

## Remaining acceptance

The fixed host resource follow-up is complete. Do not expand adjacent consumer audits. The finite seven-row signed-device/performance checklist in `stage-4-prerequisites.md` remains unexecuted; whole issue stays `in_progress`. Real microphone/TCC/signing, device switch/sleep/quit, local translation/model performance and shared-entry signed-app acceptance require their separate evidence or explicitly accepted scope deferral. Synthetic queue success does not pass those gates.
