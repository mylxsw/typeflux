# GUL-399: WhisperKit inference isolation

This increment is stacked on PR #519 (`46d76c66`, native system commands). It moves **every production WhisperKit pipeline constructor** into `TypefluxInferenceHelper`. `WhisperKitTranscriber` remains the facade used by `LocalModelTranscriber`, both `LocalModelManager` preparer factories, and `AutoModelDownloadService`. The application target no longer depends on WhisperKit. Symbol inspection found zero WhisperKit module symbols in the application executable and 5,993 in the helper.

The helper is a separate executable plus a shared protocol and worker runtime. It does not initialize Typeflux DI, AppKit UI, recording or permission prompts. The loaded model is reused within its worker. The existing standard/low-energy decoding options, supported language hints, vocabulary token filtering, final text, model preparation, idle expiry and memory-optimization cache policy are preserved. Existing sherpa-based engines remain unchanged.

## Ownership and failure behavior

- A private inherited Unix socket carries versioned, UUID-correlated, sequenced frames. Frame payloads are capped at 256 KiB, text at 128 KiB, prompts at 16 KiB and paths at 4 KiB. Progress uses one latest-value mailbox and one writer, at most ten updates per second; the final response follows the joined writer. No task is created per native progress callback.
- One operation uses each worker at a time. The independent inference pool admits at most two children, allowing preparation alongside the selected model. Failed children consume a rolling recovery budget across facade replacement. No operation is resubmitted after an IPC, loading or decoding failure.
- Preparation and operations have 30-minute supervisor deadlines; the child has a 24-hour maximum lifetime. Cleanup waits at most two seconds during ordinary termination. Retained work stays counted. Disabling, cache eviction, model switch, facade release and application shutdown fence or stop the corresponding service. Worker replacement cannot bypass the two-child cap while previous children await confirmed collection.
- Recording files are copied into a private directory, capped at 512 MiB. Successful requests remove their copy; failed requests retain it until the child is actually reaped. Pool release follows scratch cleanup. Model deletion rejects active worker leases. An inference failure stops model-download source fallback instead of loading the same failed model again.
- The parent receives typed, redacted failures. Its UI facade uses a localized unavailable message in five languages. Raw child stdout/stderr are bounded and never forwarded into errors or logs. The previous local transcription log containing the audio path and vocabulary was removed; model-load paths and raw source-failure errors were removed from the touched download logging.

The process runner gained only an explicit borrowed IPC descriptor mapped to child fd 100. Existing bounded stdio, process-group termination and confirmed-reaper behavior remain in use. Both socket endpoints have close-on-exec protection in the parent; the helper closes inheritance again after startup.

## Packaging

SwiftPM builds `TypefluxInferenceHelper`; development and release bundlers install it under `Contents/Helpers`, alongside `swift-transformers_Hub.bundle`. This location matters: the dependency's generated resource accessor searches relative to `Bundle.main.bundleURL`. A harmless Foundation probe confirmed that a helper in `Contents/MacOS` resolves the outer app root, while `Contents/Helpers` resolves the helper directory. Missing worker/resources fail bundling, and the helper rejects missing tokenizer resources before loading any model.

The release script signs the nested helper before sealing the outer app. Both development scripts sign it explicitly. The checked-in Xcode project and generator have a native helper target linked only to `TypefluxInferenceWorkerKit`, an app dependency, and a copy phase for the executable and tokenizer bundle. The new target retains macOS 13.0; `otool` confirmed `minos 13.0` on the built helper.

## Focused validation

Implementation and self-review preceded the single functional pass. All **64 Swift methods passed**: 51 XCTest methods and 13 Swift Testing methods. Two Python packaging tests also passed. There were no failing tests or functional retries. No full suite was run.

| Scope | Methods | Behavior |
| --- | ---: | --- |
| `InferenceProtocolTests` | 7 | Invalid versions/operations/frames, truncation, absolute backpressure deadline, bounded progress, sequence/final ordering, redacted engine failures |
| `WhisperWorkerTests` | 15 | Reuse, final delivery, cancellation, stale replies, busy admission, failure budgets, shutdown, delayed reaping, private audio lifetime, bundled helper probe, missing resources, real harmless crash/hang children |
| Selected `LocalModelTranscriberTests` | 11 | Whisper preparation/tokenizer behavior, no source fallback after inference failure, model deletion lease, model switch, idle/persistent caching, low-energy language/profile |
| `ManagedProcessTests` / `OwnedProcessReaperTests` | 13 / 3 | Shared process ownership, bounded output/input, cancellation, timeout, confirmed collection |
| `ModuleRecoveryBudgetTests` / `ModuleSupervisorTests` | 2 / 13 | Cooldown, retained work, generation invalidation and no operation replay |
| `test_inference_packaging.py` | 2 | Missing build inputs fail before installation; executable/resource copy; real Xcode dependency/copy/deployment contract |

Build/test subprocesses used `scripts/test_runtime.py`'s `child_environment()` to exclude runtime credentials. Exact Swift commands, in order:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests
otool -l .build/arm64-apple-macosx/debug/TypefluxInferenceHelper
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:InferenceProtocolTests|WhisperWorkerTests|ManagedProcessTests|OwnedProcessReaperTests|ModuleSupervisorTests|ModuleRecoveryBudgetTests)[./]|^Typeflux(?:Focused)?Tests[./]LocalModelTranscriberTests[./]test(?:Whisper|LocalModelManager.*Whisper|LocalInference|WhisperModel)'
python3 -m unittest discover -s scripts/tests -p test_inference_packaging.py -v
bash -n scripts/copy_inference_helper.sh scripts/build_release.sh scripts/run_dev_app.sh scripts/run_dev_attached.sh
/usr/bin/ruby -c scripts/xcode_inference_helper.rb
/usr/bin/ruby -c scripts/generate_xcodeproj.rb
```

Both binaries contained `__llvm_covmap` and `__llvm_prf_cnts`. No discovery rebuild was inserted. Three preparation builds took **299.69 s, 147.32 s and 40.18 s**, including startup/planning. The one focused coverage run took **21.97 s**. Packaging and syntax checks took **0.12 s** (Python execution reported 0.111 s). Total measured build/test command wall time: **509.28 s**, excluding review and coverage report generation.

Changed executable source-line coverage is **486/518 = 93.82%**, measured against `46d76c66`; see `local-inference-coverage.json`. Coverage uses the three host profiles and two normal-exit helper profiles from this final build only. The shared worker/protocol object files are identical between the test and helper binaries. `llvm-profdata merge -sparse` reported no mismatches; `llvm-cov show` loaded both binaries to include the helper entrypoint. Earlier preparation builds supplied no passing results or profiles. Resource files and build scripts are not executable Swift lines and are validated separately.

## Boundaries still requiring validation/work

- No actual WhisperKit/CoreML model was downloaded or loaded. Native pipeline construction, tokenizer-backed prompt encoding and actual decoding remain unexecuted; the engine file has 13/32 changed lines covered (40.62%). Helper entrypoint line coverage does not prove every watchdog branch or live native API behavior. Real-model latency, memory and sustained streaming performance have not been measured.
- The real helper probe uses the bundled layout and valid/missing tokenizer resources, but does not constitute a Developer ID release, notarization, Xcode app build or hardware/TCC validation. The Xcode packaging contract was inspected/tested, not built as a complete app. Real AppKit quit/recording integration remains untested; its four new DI/coordinator bridge lines are uncovered.
- Cancellation revokes publication and bounds waiting; uncooperative parent callbacks or filesystem copies remain retained in the supervisor. A retained child remains in the pool after a cleanup timeout. Filesystem I/O, model downloading and copying still execute in the host. The pool is an in-process budget, not a persisted health/attribution store. It is not yet integrated into the three-storage-module registry/settings health UI.
- This is file-based audio inference isolation, **not microphone capture isolation**. Process isolation does not contain arbitrary OS/host crashes, executor starvation, system-wide memory pressure or all native faults elsewhere in the app.
- The approved plan still requires further module adapters/condition-driven lifecycle wiring, media isolation, and audio/TCC/signing/performance validation before deciding on capture isolation. GUL-399 remains `in_progress`; this PR does not complete whole-issue acceptance.
