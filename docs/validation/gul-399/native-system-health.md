# GUL-399: native system command lifecycle health

Base: open draft #567, `35ef5c591035e3ea969f60b5334624ec5dc0de05`, branch `agent/arch-gpt-astra/gul-399-encoding-health`. This increment stacks on #567–#561. Earlier work through #560 is on main. Main `ceeaaef5bf4f2e5625a0654d6f3d31702821f174` includes storage-only persistent quarantine auto-recovery, persistent chat feedback and background-task window changes absent from this tested tree; preserve them during integration. Media/native domains do not opt into storage's automatic persistent reset. No GitHub PR merge or prior closure audit repeated.

## Behavior and ownership

`NativeSystemWorker.shared` now requires lifecycle readiness. A separate `NativeSystemModule` joins the registry with fixed `nativeSystem.json`, beside the existing nine media domains and three stores. Persistent reservation is once per factory generation, never per command. Factory readiness only checks executable availability off MainActor; it never invokes a probe, toggle or any command. No new executable, protocol or process pool. The existing main-executable early native-command entry remains independent of DI.

The media gate's unchanged content-free admission/fault/coalescing logic is extracted as `ModuleWorkerGate` and shared by both adapters. Media typed execution and retirement stay unchanged. The native adapter uses its own worker, fault generation, health budget and cancellation/retirement mechanism; no generic supervisor operation timeout wraps the typed command. Corrupt health is preserved until explicit reset. Health failure cannot affect another domain or restore authority to old work.

The native worker keeps one owned operation, with no queue or saved request. UUID-fenced `NativeSystemActivity` retains its slot until BOTH host completion and confirmed child reaping, including when one arrives long before the other. A duplicate old reaper cannot release a newer operation. Lifecycle cleanup cancels the current task and waits on one retained continuation; a cleanup timeout does not replace the occupied worker. Adapter release synchronously fences admission and cancels the operation, including cancellation installed after retirement starts. No task per reaper event. Direct worker shutdown now waits at most two seconds; its slot remains occupied afterward if the host/child is uncooperative. This is not a whole-application quit-latency guarantee.

Existing five-second child deadline, one 1 KiB UUID/version/operation request and response, 1 KiB stderr, borrowed IPC descriptor 100, bounded ManagedProcess execution and early child entry remain. Only Wi-Fi, Bluetooth and scroll-direction native operations are governed here. Other fixed process/script system commands keep their existing runner and are not claimed to have this lifecycle adapter. Native ABI isolation itself was already delivered and is unchanged.

Caller outcome and subsystem health are separate. Valid `notExecuted` and `unknown` responses remain those truthful outcomes without being classified as transport crashes. Valid completed replies succeed once. Timeout/nonzero exit/truncation, malformed/mismatched protocol or runner exceptions fault the generation. Launch EACCES/EPERM/ENOENT/ENOEXEC waits for explicit recovery. No raw diagnostics escape. Cancellation/revocation after launch remains unknown; before launch it can be notExecuted. A late completed reply cannot bless a revoked generation. Capability recovery never repeats the prior command or uses a hardware probe as readiness. Unknown outcome is not permission to retry.

The existing `isEnabled` presentation policy is deliberately retained: temporary lifecycle unavailability still produces a visible failure through the launcher, while permanent app shutdown suppresses late alerts. Existing explicit user confirmation and retry=false errors are unchanged. No new account permission grant or automatic system action. Broader feature/account lifecycle integration remains separate.

DI retains the native adapter and registers it beside existing modules. Test fixtures use explicit workers/injected native controls or harmless shell transports; no full DI or global mutable test bypass. Five localized health labels and the existing recovery button are exposed.

## Validation

**71 distinct focused methods validated: initial 70/71 passed, followed by final affected 25/25.** The only failure was a new fixture expecting two persistent reservations after a successful clean stop. Existing `ModuleHealthStore.cleanStop` resets a healthy generation, so restart correctly has one reservation. The assertion was corrected; no production fault behavior failed. The final 25-method scope covers all changed production behavior and the extracted gate. No full suite.

| Scope | Distinct methods | Purpose |
| --- | ---: | --- |
| NativeSystemModuleTests | 11 | pre-DI closure; no readiness probe/replay; controlled notExecuted/unknown; six process/protocol faults; four launch errors; independent media domain; corruption/clock/reset; duplicate binding/missing executable; cancel/late host and reaper; bounded shutdown; harmless real shell crash/hang; adapter release; old callback and cancellation-install races; truthful launcher failure |
| NativeSystemHealthViewTests | 1 | actual settings row and AX restore action without executing a command; screenshot inspected |
| NativeSystemWorkerTests | 5 | retained-child admission, explicit recovery after cooldown, malformed replies, cancellation/timeout/quit, injected launcher routing/no retry |
| NativeSystemProtocolTests | 4 | exact identity/version/size, injected setters and unknown effects, harmless dynamic symbol fixtures, early-entry rejection |
| AskSystemCommandTests | 8 | explicit confirmation, cancellation preserves input, injected process dispatch and localized outcomes; one method has two arguments |
| MediaExtractionModuleTests / MediaWorkerTests | 13 / 9 | extracted shared gate, generation/corruption/retirement/classification, existing process faults and shutdown |
| ModuleRegistryTests / ModuleHealthStoreTests / StorageModuleRegistryTests | 12 / 6 / 1 | shared lifecycle and persistence compatibility |
| LocalizationResourceTests | 1 | all five string tables parse |

Initial scope: **34 XCTest + 37 Swift Testing**. Final scope: **24 XCTest + 1 Swift Testing**. The existing real native CLI probe method was explicitly excluded. Injected protocol tests include a no-op probe branch, but no actual hardware probe/toggle runs. Harmless shell children exercise the production ManagedProcess transport. No user clipboard/paste/wheel, real capture/microphone/TCC, audio output, network/providers/external app launch or destructive system command. Launcher UI uses private synthetic state and injected process sinks.

Commands use scripts/test_runtime.child_environment:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <scope>
python3 -m unittest scripts.tests.test_media_packaging
```

Initial regex:
```text
^Typeflux(?:Focused)?Tests[./](?:NativeSystemModuleTests[./]|NativeSystemHealthViewTests[./]|NativeSystemProtocolTests[./]|NativeSystemWorkerTests[./](?!realCLIProbeAndFreshDisposableProcessesCompleteWithoutSystemEffects)|AskSystemCommandTests[./]|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./]|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))
```

Final affected regex:
```text
^Typeflux(?:Focused)?Tests[./](?:NativeSystemModuleTests[./]|NativeSystemHealthViewTests[./]|MediaExtractionModuleTests[./])
```

Self-review preceded functional tests. First build **258.82 s** (inner254.81) passed. Before tests, review added synchronous adapter-release cancellation plus its installation/old-reaper regression; second build **42.81 s** (inner42.48) passed. Initial inventory **3.958 s**, matched71 via native_environment/native_tools and swiftpm-testing-helper, no discovery rebuild. Host/helper LLVM coverage sections verified. Initial focused command **40.82 s** (XCTest9.424, SwiftTesting7.946), one fixture failure. Corrected assertion and removed one extra trailing blank line from extracted gate; third build **48.28 s** (inner47.95) passed. Final affected command **12.85 s** (XCTest4.769, SwiftTesting0.151), 25/25 passed. No source/test inputs changed after final build. Existing unrelated warnings remain.

**2/2 packaging checks**, reported **0.127 s**. No copied-helper probe: native early entry, helper/protocol and packaging are unchanged. Tracked total **407.665 s**, excluding packaging interpreter startup, audit/archive/extraction and screenshot inspection. Actual640×190 unavailable native-command health row inspected: label/status/recovery control and no-replay explanation visible. All run-owned jobs/children collected; no full Xcode/signing/device verification.

## Coverage and limits

Against actual base35ef5c59, **161/163 added executable lines = 98.77%**. The two uncovered lines are DI construction/registration bridges. The denominator includes30 existing gate executable lines moved to a new file; it is not all-new logic. Native worker65/65 and adapter/activity63/63 line hits do not prove every branch, allocation failure, OS command/device behavior or real app quit.

Coverage uses ONLY **5 fresh final profiles (3 host, 2 direct media helper)** from ONE final binary. Initial8 profiles are archived and excluded. Every raw profile individually validated, warning-free merge, helper included with llvm-cov --object, new Sources git add -N before extraction. No old results or mixed counter layouts; final source hashes verified. Inventory-only profile excluded. Evidence `.build/native-health-validation/final`.

- Final XCTest SHA-256: `f8c44f85ac44cb93cf6f293fc629e65c51633bdc938fb6a8740a23d49240694b`
- Initial XCTest SHA-256 (excluded): `d4d68d1408e6a1d4bbe381e86cedcacccde2752198f76b426b3f56c00beeaeff`
- Unchanged media helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`
- App/helper minimum OS13; existing XCTest runtime14 does not prove macOS13/Intel hardware support.

Inference/playback/feature adapters and broader condition-driven lifecycle remain. Next audit is the independent Whisper inference pool, including its existing per-client supervisor, native model preparation/download semantics and host/child retirement; readiness must never load/download a model or replay transcription. Retained encoding candidates/publication receipts remain untouched. Never replay writes/toggles/counts/Agent/workflows/system commands/paid generation/shutdown, or delete/recreate databases.

Remaining native/media audit and audio/TCC/signing/performance checks precede microphone capture ownership decisions. File processing does not decide live capture. Host filesystem/JSON/base64/raw raster/pasteboard/SQLite/import-export/UI, live capture/audio meter and AppKit/GPU/system memory remain boundaries. User-requested OS Quick Look is separate; existing file/semantic workers must not be duplicated. Real CoreML/model performance/full Xcode/Developer ID/notarization/macOS13/Intel/actual quit-recording remain unverified. No arbitrary host crash, system-wide OOM or power-loss guarantee. GUL-399 remains in_progress.
