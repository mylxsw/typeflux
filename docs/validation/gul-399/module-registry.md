# GUL-399: module registry and persistent health (stage 2d)

This increment is stacked on notebook PR #516, baseline `d68b035d`. The previous process, supervisor, word-book and notebook increments remain prerequisites. The overall four-stage issue is still in progress.

## Delivered behavior

`StorageModules` is the injectable production composition root used by `DIContainer`. Conversation history, word-book and notebook each retain their own typed supervisor, factory, recovery budget and health file. They deliberately have no strong dependencies on one another. The launcher shell does not await storage startup. Feature operations still execute once through their existing facades; no mutation, approval, execution claim or receipt is replayed or reconstructed.

`ModuleRegistry` validates duplicate IDs, missing dependencies and cycles before starting anything. The current closed `ModuleID` set permits three distinct registrations. Startup follows the dependency graph; independent modules continue after another startup fails. Startup tasks are deduplicated per node. Revisions fence delayed startup, including a disable issued while an earlier module in a startup batch is opening. Admission checks every ancestor's current health. Dependency observation failure also fails closed.

Disable fences the affected subgraph before awaiting cleanup. Shutdown permanently fences every registration. A single coalesced retirement task owns overlapping disable/shutdown requests and performs reverse dependency cleanup. If an uncooperative descendant has not retired by its cleanup deadline, its dependencies stay owned and fenced; a subsequent stop can finish retirement after it exits. They are not freed underneath live work. No additional replacement instance is launched to bypass retained work.

`ModuleHealthChannel` is a stable, content-free observation endpoint, limited to 16 subscribers and one latest buffered snapshot per subscriber. Cancellation removes subscriptions. State, generation, bounded task counts and typed failure codes are available without observing feature payloads. This increment provides the observation API, not the complete recovery UI.

`ModuleHealthStore` uses separate atomic, versioned JSON files (maximum read size 4 KiB) under Application Support/Typeflux/ModuleHealth. Files contain only `version`, `attempts` and `quarantined`. Disk access occurs inside bounded detached factory/cleanup work; memory-only health updates use a separate lock. A reservation is written **before** entering a factory. Four unconfirmed starts exhaust the persistent budget; another process/store instance cannot reset it simply by launching again. Normal confirmed cleanup clears it. Ten minutes of observed health allows a fresh budget on the next reservation. The existing monotonic in-process backoff/circuit remains in force.

Corrupt, oversized, unsupported or unwritable metadata prevents that module's factory from running and holds automatic recovery. It does not stop the app shell or other fault domains. An interrupted startup is a conservative recovery hint, not evidence that this module caused an application crash. `ModuleHandle.retry(resetPersistentBudget: true)` provides deliberate recovery through the bounded startup path; ordinary enable and automatic retry do not clear persistent quarantine. User databases are never removed or recreated.

`AppCoordinator` starts the registry and fences it on shutdown. `AppTerminationBarrier` gives ordinary AppKit quit a foreground cleanup lifetime before replying to the termination request, while preserving the existing screen-recording finish step. Repeated quit requests share the same completion. `applicationWillTerminate` retains the synchronous fallback fence.

## Focused validation

Validation used Xcode Swift 6.4 with `scripts/test_runtime.py`'s sanitized child environment. No full suite, discovery rebuild, external CI watch or merge was run.

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:ModuleRegistryTests|ModuleHealthStoreTests|StorageModuleRegistryTests|AppTerminationBarrierTests|ModuleSupervisorTests|ModuleRecoveryBudgetTests|RecoveringAskConversationCacheTests|RecoveringAskWordBookStoreTests|RecoveringAskNoteStoreTests|AskRecoveryJournalTests)[./]'
```

Both `__llvm_covmap` and `__llvm_prf_cnts` sections were verified before execution. Coverage replaced a plain test run.

| Scope | Reason |
| --- | --- |
| ModuleRegistryTests | Graph validation, ordered lifecycle, independent failure, deduplication, startup cancellation, disable generations, dependency failure, observer capacity, retained dependencies and overlapping shutdown |
| ModuleHealthStoreTests | New-instance restart budgets, corrupt/version/size bounds, write failure, explicit reset, healthy reset and supervised quarantine without replay |
| StorageModuleRegistryTests | Actual production composition root with three injected SQLite factories, independent disable/reopen and clean-stop persistence |
| AppTerminationBarrierTests | Foreground quit completion and repeated-request deduplication without terminating the test host |
| ModuleSupervisorTests / ModuleRecoveryBudgetTests | Existing timeout, cancellation, stale generation, retained work and circuit behavior affected by lifecycle/health hooks |
| RecoveringAskConversationCacheTests / RecoveringAskWordBookStoreTests / RecoveringAskNoteStoreTests / AskRecoveryJournalTests | Directly affected facades, truthful storage errors, durable claims/receipts and no-replay behavior |

The initial pass executed **52 methods** (50 Swift Testing, 2 XCTest). One registry test exposed overlapping dependency retirement and shutdown: the shutdown caller could return before an existing retirement finished. Cleanup ownership was coalesced, and a deterministic overlap regression was added. The final retry passed **13/13 methods** in `ModuleRegistryTests|StorageModuleRegistryTests`. In total, **53 distinct methods were validated**, with the original failed method passing on retry.

Measured command wall times, including runner startup and preparation:

| Command | Seconds | Outcome |
| --- | ---: | --- |
| Initial compilation during self-review | 191.98 | Passed; no tests executed |
| Termination integration compilation | 37.17 | Failed on actor-isolated initializer; corrected with an empty nonisolated initializer |
| Corrected compilation | 177.50 | Passed; no tests executed |
| Final pre-test compilation | 88.77 | Passed |
| Initial focused coverage run | 10.47 | 52 methods, one registry failure |
| Registry correction compilation | 84.50 | Passed |
| Focused correction coverage run | 7.99 | 13/13 passed |
| **Total measured Swift commands** | **598.38** | **579.92 build/preparation + 18.46 execution commands** |

Changed executable-line coverage is **383/412 (92.96%)**, relative to `d68b035d`; this is not project-wide coverage. See `module-registry-coverage.json` for every file and uncovered line. `ModuleRegistry.swift` uses the final successful retry profile (174/174). Every other production file was unchanged after the initial run and uses the matching initial profile, captured before rebuilding. Profiles from different Swift counter layouts were **not merged**. LLVM line coverage does not prove every branch or scheduling interleaving.

## Remaining boundaries

- Real AppKit application termination, recording-finish interaction and forced OS termination were not exercised. The quit barrier and actual storage composition were tested independently; the small DI/AppDelegate/AppCoordinator bridges remain uncovered and are included in the denominator.
- Health persistence is conservative across interrupted runs. It does not identify crash causes or guarantee durability against arbitrary host/power/storage failures. The store is owned once per module by this application runtime; coordination between multiple simultaneous application processes is not added here.
- Complete health/recovery settings UI, notices and additional production module adapters still need integration. The persistent-reset API must only be exposed as a deliberate user action.
- SQLite, JSON, registry supervision and UI remain in process. Deadline responses do not contain native crashes, process-wide OOM or executor starvation. An uncooperative descendant can keep its fenced dependencies retained until a later stop or process exit.
- Native system-command and media/local-model process isolation, plus audio/TCC/signing/performance verification before audio isolation, remain required approved work. This PR is not whole-issue acceptance.
