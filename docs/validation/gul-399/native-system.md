# GUL-399: isolate native system commands (stage 3a)

This increment is stacked on recovery UI PR #518, baseline `2ca136aa`. The overall approved stability plan remains in progress.

Wi-Fi, Bluetooth and scroll-direction toggles now execute in a disposable child of the existing app executable. `AskSystemCommandRunner` no longer calls CoreWLAN or dynamically resolved native setters in the application process. The other fixed executable commands retain their existing bounded runner; screen cleaning remains a UI operation. The built-in system actions are launcher actions, not Agent tool registrations. Existing Agent approvals, durable execution claims/receipts and unknown-execution handling are unchanged.

`NativeSystemRequest` and `NativeSystemResponse` use protocol version 1, a fresh UUID, an operation allowlist and a typed outcome. Each input/output is limited to 1 KiB. The only operations are the three toggles and a harmless readiness probe. The parent checks version, request identity, operation, exit status and output bounds before accepting a result. The child receives a minimal environment, no arbitrary command string and no user payload. Raw stderr, framework errors and malformed response contents never become UI messages.

The native adapter resolves a control and reads the old state before entering the setter. Failures before setter entry return `notExecuted`; once a setter is entered, errors or failed readback return `unknown`. The parent also reports unknown after a crash, timeout, malformed reply or cancellation following process launch. A successful request means a matching response confirmed readback. It never means an accepted request alone succeeded. The localized failure does not offer automatic retry and tells users to check the system state before another attempt.

`NativeSystemWorker` owns at most one command, with no queued mutations, a five-second production deadline, bounded cleanup and the existing monotonic recovery budget. Every new accepted action gets a new child, but a failed action is never replayed. After a failure, only a later explicit action can proceed once the budget permits it. The process reaper now supplies a callback after confirmed direct-child collection. If a timed-out child remains unretired, this module rejects replacement work even after cooldown expires. The callback does not execute under the reaper lock. Losing provable process ownership conservatively keeps this channel unavailable.

DI owns the production shared channel, and AppCoordinator fences/cancels it during stop and awaits its bounded shutdown during ordinary quit. After shutdown, late native failures retain their unknown-result semantics but do not open an alert during termination. The launcher captures the runner that actually accepted the action before awaiting, preserving the same lifecycle decision for its response.

## Packaging and deployment

Dispatch happens in `TypefluxApplication.run` before `DevLauncher`, NSApplication or application DI. Both `Sources/TypefluxCLI/main.swift` and `app/TypefluxXcodeMain.swift` enter this shared path, so the Xcode app cannot accidentally open its UI for a native-worker invocation. No new packaged executable, resource path, entitlement or signing layout is introduced. Existing SwiftPM/release scripts and the Xcode TypefluxKit dependency already include the added library source files.

The instrumented app's `LC_BUILD_VERSION` was inspected with `otool`; `minos` remains **13.0**. A real built CLI probe is exercised twice in the focused tests, without changing any system setting. A separately signed release/Xcode app and actual hardware/TCC behavior were not exercised. No Wi-Fi, Bluetooth, scroll preference, shutdown/restart or destructive command was run for validation.

## Focused validation

Self-review preceded execution. Xcode Swift 6.4 commands used `scripts/test_runtime.py`'s sanitized child environment. No full suite, discovery rebuild, external CI watch or merge was run.

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:NativeSystemProtocolTests|NativeSystemWorkerTests|AskSystemCommandTests|ManagedProcessTests|OwnedProcessReaperTests|ProcessCommandRunnerTests|ModuleRecoveryBudgetTests|AskWorkflowRunnerTests|ClipboardCaptureWorkerTests)[./]'
```

Both `__llvm_covmap` and `__llvm_prf_cnts` were verified before execution. The single focused coverage pass passed **65/65 methods** (30 XCTest, 35 Swift Testing); no failed-test retries were needed.

| Scope | Behavior verified |
| --- | --- |
| NativeSystemProtocolTests | Size/version/identity/operation validation, setter-once behavior, pre/post-set failure classification, bounded Bluetooth readback, harmless injected C function bindings, missing library/symbol and child input rejection |
| NativeSystemWorkerTests | Real CLI probes; crash without replay; later explicit recovery; malformed/nonzero/flooded responses; pre/post-dispatch cancellation; timeout; busy admission; quit fencing; confirmed PID collection; unretired child prevents replacement; localized no-retry outcomes |
| AskSystemCommandTests | Fixed command plans, launcher/search aliases and explicit confirmation before dispatch |
| ManagedProcessTests / OwnedProcessReaperTests / ProcessCommandRunnerTests | Shared process lifetime, bounded streams, cancellation, descendant cleanup, delayed collection and callback outside the reaper lock |
| ModuleRecoveryBudgetTests | Existing cooldown/circuit behavior reused by the native channel |
| AskWorkflowRunnerTests / ClipboardCaptureWorkerTests | Directly affected process/reaper consumers retain their fault and cancellation behavior |

Measured wall times include command preparation and startup:

| Command | Seconds | Outcome |
| --- | ---: | --- |
| Initial instrumented compilation | 227.98 | Passed; no tests executed |
| Final compilation after self-review added shutdown notice suppression | 110.54 | Passed |
| Focused coverage pass | 29.75 | 65/65 passed |
| **Total** | **368.27** | **338.52 build + 29.75 test commands** |

Changed executable-line coverage relative to `2ca136aa` is **215/228 (94.30%)**, not project-wide coverage. `native-system-coverage.json` lists each file and uncovered line. All three raw profiles were produced by this pass against one final binary and merged with `llvm-profdata`; no old results or profiles with different counter layouts were reused. Swift line instrumentation can mark closure declarations covered when constructed: this percentage does **not** mean live Wi-Fi/Bluetooth/scroll APIs were exercised. Those operations were deliberately replaced with harmless controls. The app startup/DI/quit bridges and the actual late-alert branch are not covered in the parent test profile; the real CLI probe verifies the shared startup path functionally in the child. Remaining branch/scheduling interleavings and real hardware behavior are not inferred from line coverage.

## Remaining approved work

- These native operations have a dedicated bounded channel; they are not yet registered in the three-storage-module health registry/settings UI. Additional module adapters and condition-driven lifecycle wiring remain stage-2 work.
- Existing fixed shell commands, preference toggles and UI-only actions retain their current behavior. The new explicit unknown outcome contract applies to the three isolated native toggles.
- The shared launch and quit bridges are thin production integration points; tests avoid constructing unrelated audio and hotkey services. Actual AppKit quit/recording coordination remains unverified.
- A child stuck in an uninterruptible kernel call can stay retained and block this module until it exits or the process ends. The bounds do not guarantee recovery from host/kernel failures, process-wide OOM or arbitrary main-process bugs.
- WhisperKit/CoreML still loads and transcribes in-process through `LocalModelTranscriber` and `WhisperKitTranscriber`. Local-model/media isolation, plus audio/TCC/signing/performance validation before audio isolation, remain required. This PR is not whole-issue acceptance.
