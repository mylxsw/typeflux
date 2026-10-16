# GUL-399 module supervision: stage 2, first integration

This change builds on PR #511 (commit `1b5b3fc6`). It is a separate stacked PR,
not a replacement for that PR. The complete four-stage stability plan remains
in progress.

## Runtime behavior

`ModuleHandle` is a stable facade over a typed `ModuleSupervisor`. Factories,
operations and cleanup execute outside the supervisor actor. A module owns at
most one factory, one cleanup, one recovery timer, eight operations and eight
startup waiters by default. Overflow returns an explicit error. Startup,
operation and cleanup budgets default to 5, 15 and 2 seconds. Policy validation
rejects non-finite/non-positive/oversized budgets and concurrency outside 1...64.

Deadlines and cancellation complete each caller once. They do not pretend an
uncooperative Swift task stopped: it continues occupying its slot, the failed
generation is quarantined, and no replacement starts until every old operation
and cleanup actually returns. A late factory result is disposed, never installed.
Generation checks also cover the suspension between obtaining a service and
admitting an operation. Recovery spends the existing 1/2/4-second rolling budget
and 300-second circuit cooldown; simultaneous failures spend it once. A
configuration hold requires explicit retry. Disable and permanent shutdown fence
admission, cancel timers and revoke delivery; re-enabling cannot undo shutdown.

`ModuleHealth` exposes a content-free snapshot: phase, generation, pending startup
callers, retained operations, lifecycle work and typed failure. It does not store
user content or underlying error messages. This increment does not yet implement
a dependency graph, persisted health records or health UI/observation.

## Production wiring

`DIContainer` owns one `RecoveringAskConversationCache` and accepts a replaceable
cache factory. The conversation window accepts that stable cache independently
of its launcher UI. `AppCoordinator.stop()` fences it synchronously before
scheduling actor cleanup, including when AppKit termination gives no further actor
turn. The existing clipboard stop path remains in place.

Every `AskCaching` method forwards once through the same supervised handle.
Storage failures invalidate the connection; approval/binding failures only fail
that operation. Supervisor failures map to the existing fail-closed `.storage`
contract. No operation is replayed, no empty journal substitutes for unavailable
storage, and durable execution claims/receipts remain in the original SQLite
file. Cleanup waits for old calls before allowing a replacement connection.

In-process SQLite is still capable of a native crash or blocking an executor.
These deadlines are cooperative-runtime admission/delivery bounds, not process
isolation or immunity to global executor/host failure. Shutdown initiates bounded
cleanup without waiting forever for uncooperative work; the OS releases resources
on process exit. Other modules still need explicit adapters and lifecycle wiring.

## Notebook and word-book audit for the next integration

No notebook or word-book schema/API behavior changes in this increment.

- `SQLiteAskNoteStore.read` and `SQLiteAskWordBookStore.read` collapse failed reads
  into nil/empty collections. UI reloads and notebook tool listing cannot tell
  storage failure from an empty library. Both use synchronous serial queues.
- Notes close their connection when initialization fails, but have no reopen
  path. `AskNotesViewModel.saveDraft` retains an unsaved body when a write fails;
  a failed baseline read currently appears as a conflict. Preserve this draft and
  compare-and-replace behavior when introducing typed asynchronous failures.
- Word-book initialization logs failure without closing the partial connection.
  Its write helper posts a change notification even after failure. There is no
  recovery or transaction around the record read/modify/upsert sequence.
- `AskWordBookRecorder.record` marks a lookup recorded before checking persistence.
  Its toggle returns the intended starred state even when `setStarred` failed.
  `AskWordBookViewModel.toggleStar` similarly displays success unconditionally.
- The next adapter must expose read/write failure to those callers, retain visible
  data/drafts, close failed handles, and reopen with the same bounded lifecycle.
  No automatic retry of a toggle, lookup counter increment or note mutation is
  allowed. Durable mutation identity/result checks are necessary before any later
  replay feature. Do not delete or recreate user databases to recover.
- Relevant future suites: `AskNotebookStoreTests`, notebook view-model/tool tests,
  `AskWordBookStoreTests`, recorder/view-model tests, and window wiring tests. They
  were audited, not executed as evidence for an unimplemented migration.

## Focused validation scope

- `ModuleSupervisorTests`: admission/policy checks, single startup, backpressure,
  cancellation, stale generation, operation/startup/
  cleanup deadlines, disable, shutdown, recovery deduplication, circuit cooldown,
  configuration hold, no action replay, cancelled-call storage failure.
- `ModuleRecoveryBudgetTests`: existing rolling budget and stable-reset behavior.
- `RecoveringAskConversationCacheTests`: lazy opening, real SQLite failure/reopen,
  preserved claims/receipts/account scopes, no replay, blocking factory and shutdown.
- `AskConversationWindowServicesTests`, `AskOpenChatTests`: launcher availability
  and direct conversation-window callers.
- `AskRecoveryJournalTests`, `AskRecoveryInteractionTests`: durable execution
  semantics and user recovery/approval interactions.

The first preparation build was invalidated by source changes made during final
self-review; no tests ran from that build. Final validation uses the explicit
instrumented native build plus prebuilt focused test command documented below,
working around the previously documented Swift 6.4 discovery/coverage issue.
The initial focused pass completed all **54 test methods** (2 XCTest and 52
Swift Testing) in seven explicitly selected suites. After reviewing the results,
two supervisor-test waits were strengthened to require both zero old operations
and completed cleanup; the smallest containing suite is revalidated below. No
production behavior changed after that pass (only a SwiftLint comment).

Commands, run with the sanitized environment from `scripts/test_runtime.py`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel \
  --filter '^Typeflux(?:Focused)?Tests[./](?:ModuleSupervisorTests|ModuleRecoveryBudgetTests|RecoveringAskConversationCacheTests|AskConversationWindowServicesTests|AskRecoveryJournalTests|AskRecoveryInteractionTests|AskOpenChatTests)[./]'
# After strengthening two asynchronous test waits and rebuilding:
swift test --build-system native --skip-build --enable-code-coverage --no-parallel \
  --filter '^Typeflux(?:Focused)?Tests[./](?:ModuleSupervisorTests)[./]'
```

The test bundle's `__llvm_covmap` and `__llvm_prf_cnts` sections were verified
before execution. Coverage is measured for added executable production lines
relative to `1b5b3fc6`, not claimed as whole-project coverage. The final coverage
record includes the original focused profile and the supervisor-only rerun.

Measured preparation: approximately 209.60 s for the source-invalidated first
build (log timestamps); then 110.81 s and 77.60 s for preparation/self-review
builds, and 43.28 s for the final pre-test build. The initial focused test command
took 22.31 s including runner startup and coverage export (test phase 13.761 s).
The follow-up build and supervisor-only rerun timings are recorded below.

The actual `DIContainer` startup and `AppCoordinator.stop()` lines are compiled
but not executed by these fixtures. Their injected cache/handle and window
callers are tested; signed application startup/exit and real native crash
containment remain later validation. No full suite, device/TCC/audio/signing or
performance validation was run, and no external CI result is claimed.


Final result: **54/54 methods passed**; the strengthened supervisor suite also
passed **13/13** on its focused rerun. The follow-up build took **65.65 s**, and
the rerun command **12.08 s** (test phase **1.212 s**). All preparation/build/test
commands together took approximately **541.33 s**, including the invalidated
preparation build; no failing test retry or broad/full-suite run occurred.

Changed executable production-line coverage: **320/331 (96.68%)**. The supervisor
itself is **265/268 (98.88%)**; the handle, policy/admission and changed cache
adapter lines are **100%**. See `module-supervisor-coverage.json` for every file
and the remaining uncovered lines. Eight uncovered DI/coordinator lines account
for the real-app lifecycle validation boundary noted above. Focused SwiftLint
checks for the new core and changed cache/test files and `git diff --check` pass.
Existing unrelated compiler warnings remain.
