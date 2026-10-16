# GUL-399: inference host retirement prerequisite

This independently reviewable prerequisite is stacked on #568 (`bd02db5e5f16905f20676798b3ed932c420b9075`, `agent/arch-gpt-astra/gul-399-native-health`). It fixes an ownership gap before adding the Whisper pool lifecycle adapter. **Whisper pool registration, persistent health, fault classification and capability-only recovery are still pending.** The shared pool remains unmanaged in this slice. No settings or other presentation changes.

## Problem and change

Previously, `WhisperWorkerRetirement` released its two-client pool admission, scratch directory and model-path leases after the process result and reaping callback, even if a dispatched host copy or an awaited consumer callback was still running. Cancellation of the task cannot make those uncooperative operations finish.

Every admitted client request now acquires a host activity under the retirement lock and releases it on all return/error paths. Cleanup requires actual child collection, completion of the process runner **and zero host activities**. Once collection/result retirement begins, new host requests are rejected even if an injected transport socket remains open. Filesystem cleanup still runs away from the global process reaper, and pool admission is released only after that cleanup attempt returns.

The transcribe cancellation handler now covers copying and final delivery as well as socket exchange. Cancellation stops the child promptly where the process implementation permits, but retains the occupied slot, path protection and scratch while host work continues. An injectable copy function tests this boundary; production retains the existing regular-file/512 MiB validation and private copy implementation. There is no mutable global test bypass.

`WhisperKitTranscriber` delivers its final snapshot inside the same admitted client request. It checks owner/cancellation before and after the final consumer callback, and the client checks cancellation/stopped state before returning success. A successful request still removes its private audio after final delivery; failed/cancelled requests retain it until retirement. An already-entered callback may have effects that cancellation cannot undo. This does not promise transactional callback delivery or filesystem cleanup durability.

No changes to the helper, wire protocol, model configuration, prompt/language options, other STT providers, download consent, source fallback, model selection, publication or encoding receipts. No request/prepare/download/transcribe retry was added. `checkUnused` remains a read-only path-ownership check, including when the pool is disabled. Existing two-client limit, 1800 s default request budget, 86400 s process budget, bounded IPC, private 0700 scratch and 2 s pool shutdown wait remain. A timed-out shutdown does not mean host work has finished; admission stays occupied. Filesystem calls/callbacks may remain uncooperative indefinitely, and metadata checks do not form an immutable source transaction.

## Audit and remaining adapter work

Inspected `WhisperWorkerPool`, `WhisperWorkerClient`, `WhisperKitTranscriber`/owner, `LocalModelManager`, `LocalModelTranscriber`, inference messages/socket/server/helper engine, DI/quit and their tests. The per-transcriber ModuleHandle already performs explicit preparation, which may load/download a model. A future pool factory must only check capability and must never call that factory/prepare/probe/download/transcribe automatically. Existing source-fallback suppression (`LocalInferenceUnavailable`) stays intact.

Next: separate fixed inference ID/health file and ModuleWorkerGate integration; classify valid engine refusal separately from process/protocol faults and launch configuration errors; fence old clients across pool generations, without replacing occupied capacity or replaying audio. Audit the current preparation failure protocol (the server closes on prepare errors) before classifying it. Preserve content-free, bounded, off-UI health and explicit reset; media/native/inference must not opt into main's storage-only automatic quarantine reset. Existing `markFailed` semantics are unchanged here and are not claimed to provide that classification.

Main at audit was `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`; storage auto-recovery/chat feedback/background-task changes are outside this stacked tree. Existing PR bases are preserved. No PR was merged and no CI was awaited.

## Focused validation

Implementation and self-review preceded the functional pass. **33/33 XCTest methods passed in one pass**, no compilation or functional failures/retries:

- 21 `WhisperWorkerTests`: 6 new regressions cover cancelled progress retaining both capacity and model paths, final facade callback plus owner stop/bounded shutdown, cancellation during an uncooperative copy, failed copy before delayed child collection, stopped final consumer rejecting success, and rejection after collection despite an open fixture socket. Existing cases cover normal reuse/final delivery, input failures, two-client saturation, delayed reaping, cancellation, malformed frames, launch errors and harmless crash/hang children.
- 7 `InferenceProtocolTests`: frame bounds, ordering, coalescing/backpressure, injected engine behavior and failure redaction. No model is loaded. Real engine methods only exercise rejection before any pipeline construction.
- 5 selected `LocalModelTranscriberTests`: no alternate download-source retry on inference failure, model deletion protection, selected-model replacement and two cache lifetime cases. Factories/remote behavior are injected; model deletion uses private synthetic directories.

The existing copied-helper test actually copies the inference helper/resources into a private app layout, probes protocol readiness without preparing a model, rejects a wrong-direction message and verifies missing-resource exit. Two inference packaging checks also passed. No actual weights/CoreML inference, download/provider/network, microphone/screen capture, TCC, audio output, user clipboard/paste/wheel, external application launch, full suite, full Xcode build, signing/notarization or hardware validation. No layout change, so no screenshot.

Commands:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in test executable and inference helper.
# Inventory through test_runtime.native_environment/native_tools + swiftpm-testing-helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:WhisperWorkerTests[./]|InferenceProtocolTests[./]|LocalModelTranscriberTests[./](?:testLocalInferenceFailureDoesNotRetryAnotherDownloadSource|testWhisperModelDeletionWaitsForItsWorkerLease|testWhisperModelSwitchStopsPreviousCachedWorker|testWhisperKitTranscriberCacheExpiresAfterIdleKeepAliveWindow|testWhisperKitTranscriberCacheDoesNotExpireWhenMemoryOptimizationDisabled)(?:\(|$))'
python3 -m unittest tests.test_inference_packaging  # cwd: scripts
```

Two preparation builds passed: 121.32 s and 47.01 s (inner build 118.30/46.69 s). The first reported a new function-reference Sendable warning; after it exited, the default copy closure was made explicitly Sendable and rebuilt **before any functional tests**. No new source warning remained; existing unrelated warnings/deprecation notices remain. Inventory 3.926 s; focused command 32.75 s (XCTest 5.987 s); packaging reported 15.654 s. Tracked sum **220.660 s**, excluding packaging interpreter startup, inspection/archive/extraction and platform/git operations. No source/test input changed after the final build.

## Coverage evidence

Changed executable lines against actual PR base `bd02db5e`: **54/54 = 100%** (client 46/46, facade 8/8), including moved copy and final-delivery lines. This is line coverage, not all-branch/native allocation/model/device/watchdog proof.

Only **five fresh profiles from the final binary**: three host and two copied inference helper profiles. Every raw profile was individually validated, then merged without warnings. Inventory profile excluded; no earlier-run profiles or counter layouts reused. The inference helper was supplied as `llvm-cov --object`. Matching binaries/profiles and production source hashes are archived under `.build/inference-retirement-validation/final`; hashes were verified unchanged after testing. These local evidence files are not shipped application artifacts.

- XCTest SHA-256: `d13c35143044106fa473f9c0327fd1c3278b4fb453498c9b9eadf1e875e32b2f`
- Inference helper SHA-256: `f48287152da7678af8bb295b13e470b80c10f122a30528c6d6588b737a9f6e72`

Real model performance, signed device behavior and macOS 13 Intel remain unverified. Host filesystem/JSON/raw memory/UI/system memory and capture are separate boundaries. There is no arbitrary host crash, system OOM or power-loss guarantee. GUL-399 remains in progress.
