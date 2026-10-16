# GUL-399: Whisper inference lifecycle and persistent health

Stacked on #569, actual base `4ca4f6fcbc1bd39971fc191523c3433c18bd6914` (`agent/arch-gpt-astra/gul-399-inference-retirement`). This uses its host/child retirement barrier; it does not repeat that prerequisite. Main remains `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`. Concurrent storage-only automatic quarantine recovery, chat feedback and background-task changes are outside this stacked tree. Preserve them on landing; inference, native and media domains require explicit persistent reset. No PR was merged or CI awaited.

## Capability and ownership

`WhisperWorkerPool.shared` now requires lifecycle binding and readiness. `WhisperInferenceModule` registers independent `ModuleID.whisperInference` / `whisperInference.json` beside nine media domains, native commands and the unchanged three stores. It reuses ModuleWorkerGate and the registry/supervisor core, with one coalescing observer. No new worker, executable, global pool or per-transcriber supervisor was introduced.

The factory only checks helper executable availability off the UI actor and returns the same pool. It never invokes a probe, model preparation, download, transcription or the existing per-transcriber factory. Persistent reservation happens once per pool factory generation, not per client, request, chunk or callback. Existing bounded content-free health persistence, four-reservation quarantine, corruption preservation, explicit reset and stable/clean health semantics remain. Availability does not prove signing, model resources or native readiness.

Each pool entry captures its original generation. Faults immediately fence sibling admission and late output, before the observer performs cleanup. Cleanup cancels owned clients and waits on one continuation until actual entries retire. A cleanup timeout leaves the occupied pool in place; it does not create replacement capacity. Adapter release fences and stops its own clients; releasing a failed duplicate binding cannot stop the first adapter's clients.

The existing two-client limit, model-path ownership, private 0700 scratch, regular-file/512 MiB audio copy, 1800 s default request and 86400 s process limits, ordered bounded IPC and 2 s direct shutdown wait remain. Slots, paths and scratch survive process collection, runner completion and all admitted host copy/socket/consumer work. Cleanup runs away from the global reaper. A bounded shutdown wait does not mean uncooperative callbacks/filesystem operations have ended. `checkUnused` remains a read-only ownership query even when inference is unavailable, so explicit model management is not unnecessarily blocked.

## Failure and explicit caller semantics

Model preparation errors now return the protocol's existing valid `.failed` terminal, matching transcription errors. The schema/version are unchanged. This is a controlled engine/model/input failure, without a typed reason or raw diagnostics; it is not proof of a subsystem crash. The client still fails and stops; remaining private audio retires through the ownership barrier. It never retries the operation.

Valid `.failed` replies do not fault the pool. Process failure/nonzero exit, timeout, truncated process output, missing terminal, malformed framing, UUID/sequence mismatch or mixed response fields do. Launch EACCES/EPERM/ENOENT/ENOEXEC waits for explicit capability recovery. Host request validation and source/copy refusals stay separate. Cancellation and revoked generations do not count as new faults. No model path, audio, text, URL or credentials are persisted in health metadata.

A cached stopped client cannot obtain a new generation. `WhisperKitTranscriber.prepare` checks actual client reusability instead of accepting an already-started handle as readiness. `LocalModelTranscriber` discards an unavailable cached facade only on its next existing caller-driven operation and constructs a new instance then. Pool recovery itself does not warm a model or resubmit old audio. Existing per-transcriber startup/operation 1800 s, cleanup 2 s, maxInFlight 4 and automaticallyRecover=false remain. Source-fallback suppression through LocalInferenceUnavailable, model selection, prompt/language, download consent and other providers remain unchanged.

`LocalModelManager` gained an explicit pool injection seam for path-ownership tests; production still uses shared. Standalone fixtures inject pools/engines rather than starting full DI. Original capture/account/source authority remains feature-owned; health readiness is not a new permission grant. An already-entered callback's effects cannot be rolled back. Filesystem snapshots are not immutable transactions.

## Focused validation

**77/77 distinct methods passed in one functional pass (57 XCTest + 20 Swift Testing), no compilation or functional failures/retries.** Implementation and self-review preceded the pass.

- 9 new WhisperInferenceModuleTests: fail-closed defaults; once-per-generation reservation; controlled prepare/transcribe refusals; source/request errors; nine process/protocol faults; four launch configuration errnos; independent media budget; corruption/reset/missing helper/duplicate binding; uncooperative consumer and delayed reaping; old facade rejection; owner release; automatic and explicit capability recovery with no preparation/transcription replay.
- 1 actual settings view test exercises the restore-access button with synthetic unavailable state and confirms no client was created. The 640×190 screenshot was inspected and is included alongside this report. Five localized labels were added.
- 21 WhisperWorkerTests include all six #569 retirement regressions, copied inference-helper resource/protocol probes without preparation, and harmless shell crash/hang children.
- 7 InferenceProtocolTests; 6 selected LocalModelTranscriberTests, including the new next-explicit-call cache replacement and model deletion protection using an injected pool.
- 13 MediaExtractionModuleTests, 12 ModuleRegistryTests, 6 ModuleHealthStoreTests, 1 storage compatibility method and 1 localization parser method.

Two inference packaging checks passed. The existing copied-helper test executes the copied helper only for resource/protocol readiness and invalid-message rejection, never model preparation. Real media helper calls use private synthetic inputs in mapped compatibility tests. No actual Whisper weights/CoreML inference, model downloads, provider/network requests, capture/microphone/TCC, audio output, user clipboard/paste/wheel, external applications, full suite, full Xcode build, signing/notarization or hardware tests.

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in XCTest, inference and media helpers.
# Inventory via native_environment/native_tools and swiftpm-testing-helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:WhisperInferenceModuleTests[./]|WhisperInferenceHealthViewTests[./]|WhisperWorkerTests[./]|InferenceProtocolTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaExtractionModuleTests[./]|LocalModelTranscriberTests[./](?:testLocalInferenceFailureDoesNotRetryAnotherDownloadSource|testWhisperModelDeletionWaitsForItsWorkerLease|testWhisperModelSwitchStopsPreviousCachedWorker|testNextExplicitCallReplacesUnavailableCachedWhisperWithoutReplay|testWhisperKitTranscriberCacheExpiresAfterIdleKeepAliveWindow|testWhisperKitTranscriberCacheDoesNotExpireWhenMemoryOptimizationDisabled)(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))'
python3 -m unittest tests.test_inference_packaging  # cwd: scripts
```

Both builds passed: 278.51 s and 35.02 s (inner 274.60/34.72 s). The second added the automatic capability recovery regression after the first build exited and before functional testing. No production edits after the first build; no source/test inputs changed after the second. Inventory 4.391 s; test command 33.45 s (XCTest 8.659 s, Swift Testing 0.566 s); packaging reported 7.490 s. Tracked sum **358.861 s**, excluding packaging interpreter startup, audit/archive/extraction/inspection and platform/git operations. Existing unrelated compiler warnings and trailing-closure/deprecation notices remain.

## Coverage and remaining boundaries

Changed executable coverage against actual base `4ca4f6fc`: **157/162 = 96.91%**. Uncovered: two DI composition bridges, one model-management failure-cleanup forwarding line and two default test-protocol extension lines. Pool 64/64, client 49/49, adapter 25/25, facade 12/12 and child server 4/4 changed lines hit. These line hits are not all-branch, allocation, device, watchdog, real model or real quit proof.

Only **seven fresh profiles from one final binary**: three host, two copied inference helper and two direct media helper. Each raw profile validated individually; merge warning-free. Both helpers supplied as llvm-cov --object, new Sources included with git add -N. Inventory profile excluded. No old profiles/results/counter layouts reused. Matching binaries/profiles and unchanged production hashes are archived in `.build/whisper-health-validation/final` (local evidence, not application artifacts).

- tests SHA-256: `d46bc48cbc5917c78da44b53469f0ee9911ef7a6396def78f190c2222d1d3992`
- helper SHA-256: `5ead3bd07eb5a8942f5f89f0ea93bb42288ac86b2e5ff03601c627f39bf35b46`
- media SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`

App and inference helper load commands retain minOS 13.0; this is not macOS 13 Intel hardware validation. Playback/feature adapters and broader condition-driven lifecycle, remaining native/media audit, audio/TCC/signing/performance before microphone capture ownership, real model performance/full Xcode/Developer ID/notarization/actual quit and recording remain required. Capture/live audio meter and OS QuickLook remain separate boundaries. Host filesystem/JSON/raw memory/pasteboard/SQLite/import-export/UI/AppKit/GPU/system memory remain. No arbitrary host/native crash, systemwide OOM or power-loss guarantee. GUL-399 remains in progress.
