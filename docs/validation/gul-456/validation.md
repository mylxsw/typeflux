# GUL-456 C4 validation

Baseline: `3256b06c03cd22b9c069853912954b8d1d07f8fc` (main after #694).

Final result: **113 distinct focused test methods validated**, including all
seven new recording-client methods and the new local-title method. The final
instrumented run passed **73/73 methods in six directly affected suites**, exit 0,
in **93.988 s** total (**78.71 s** build/discovery, **10.85 s** execution phase;
Swift Testing reported **6.066 s**). This was an incremental rebuild, not a
verified runner-cache hit. The other 40 methods passed in the earlier execution:
31 XCTest methods, eight context-compaction methods and one auxiliary HTTP method.
Those paths were unchanged by the later typed summary-composition extraction.

The final profile covers **16/16 changed executable lines (100%)** against the
baseline. All eight coverage command attempts total **1106.762 s**, including
cold dependency preparation, build/scope failures, failed test attempts and their
retries. No passing result was reused from a prior run of this issue.

The production change adds a host-internal provider-completion protocol and
constructor/dependency injection at the existing Ask call sites. It leaves the
transport implementation, model/context planning and execution ownership checks
in place. See `caller-audit.md` for the six Swift caller paths and the bounded
read-only Go research/durable audit.

## Scope and test isolation

The recording actor exercises normal answer and queued foreground summary through
conversation selection/resume, local title through its claim/result entry,
workflow through send and the local engine, and auxiliary capture through the
factory-composed summary closure. The background case takes that exact factory
closure into an engine with isolated storage and triggers summary preparation
from persisted synthetic history. It collects the held preparation task.
Reflection obtains private task handles. A typed `makeSummary` composition
helper is shared by `makeAPI` and isolated host tests; tests never invoke a
function value recovered from actor reflection. No existing property visibility
is widened.

The fake records synthetic provider/configuration and prepared payload fields,
callback presence, usage and progress. Negative cases cover unsupported bindings,
foreign device/account, unresolved and excluded model selection, persisted receipt
replay and auxiliary failure. Held conversation tasks exercise cancelled and
replaced snapshots and account reset; the workflow task checks cancellation
before progress and receipt publication. These cases retain the existing durable
late-usage behavior; no new accounting semantics are asserted.

Existing focused suites cover Quick Ask, default protocol HTTP transport,
provider contracts, stream parsing, context recovery, binding, durable late usage,
prompt/summary boundaries, factory overrides and workflow ownership. No full UI
suite, real provider request or CI wait is included. `focused-suites.txt` records the overall affected-suite inventory; the signed-out
conversation-model regression is selected as a method filter. Exact commands for
each attempt are the first line of its raw log. The final successful command is:

```sh
make coverage SUITE="AskModelCompletingTests AskConversationTitleTests AskApplicationAPITests AskQuickAskTests AskStreamTests AskWorkflowAssistantSessionTests"
```

## Self-review

Reviewed the complete constructor-to-receipt flow, nil callbacks, failure receipts,
binding/account/run/inference guards, tool-call rejection for titles, and task
collection. Verified that resolved credential configuration never becomes
runtime-facing state, prompt content or new log content. All test credentials
are synthetic. The default transport and concrete utility overloads remain intact.
Test review corrected UUID canonicalization, forced snapshot reload for receipt
replay, and private task access without widening the production interface.

Shared runtime authority, dispatch/state compatibility, peer negotiation and
alternate-runtime end-to-end acceptance remain in backlog GUL-457. No Go code
was changed or tested in this read-only audit. Live providers and full UI behavior
are outside the local evidence.

## First-use build failure

The first coverage attempt exited 2 before any tests ran: **536.223 s** total
wall time (**533.48 s** runner). It included dependency resolution and a cold
application/test build. New tests accessed the private operation table directly;
they now capture it through a test-only reflection helper. The source correction
while the compiler was still finishing also produced the recorded modified-input
build error. Subsequent validation keeps source fixed until the command exits.
The initial scope also contained three stale suite names; the final selection
uses verified source declarations. Raw output is in `coverage-run.log.gz`.

The next attempt compiled successfully but stopped before execution on an
unmatched signed-out method filter (**78.685 s**, runner **78.61 s**). Corrected
`AskLocalModeTests` to the declared `AskLocalModeIntegrationTests`; raw output:
`coverage-scope-check.log.gz`.

The first execution selected 113 methods (**35.728 s** total; **30.82 s**
build/discovery; **4.81 s** execution). All **31 XCTest methods** passed, including
the signed-out conversation integration and provider HTTP/context cases. Four
Swift Testing suites completed, and the held conversation test passed, before
the new auxiliary factory test crashed while invoking a reflected async closure.
Two new test expectations also failed: acknowledged receipts intentionally do
not resubmit, and the test API does not enforce account separation. The corrected
checks assert no repeat transport for acknowledged receipts and supply a missing
session for the unauthorized case. Those corrected conversation tests then
passed in the smallest-suite retry. Raw output: `coverage-first-execution.log.gz`.

The isolated retry (**170.627 s**) reproduced signal 11 at the invocation of the
reflected closure. Debugger attachment was denied (`crash-backtrace.log.gz`), and
Swift's optional crash-symbolication subprocess did not finish; only that exact
diagnostic child was stopped, then the test result was collected. An explicit
optional-unwrapping experiment compiled but its first method selector missed
Swift Testing's backtick spelling (**71.079 s**, no tests); discovery is recorded
in `port-methods.txt`. The corrected single-method retry (**34.021 s**) still
crashed. The final implementation shares the existing closure through the typed
`makeSummary` factory instead of invoking function values obtained by reflection.
The failure logs preserve all attempts; no provider request was made.

## Final coverage and portable evidence

The typed-composition retry passed **7/7 new host-entry methods**, exit 0, in
**86.411 s** total (**80.07 s** runner, **5.49 s** execution phase). Self-review
then moved background task capture before fake release, while the actor is
suspended, and made workflow cleanup release its held fake before a throwing
assertion. The final 73-method run revalidated these changes, the composition
factory, local title, Quick Ask, stream callbacks and workflow generation guards.

| Production file | Covered / changed executable lines |
| --- | --- |
| `AskConversationModel.swift` | 2 / 2 |
| `AskConversationModel+Title.swift` | 3 / 3 |
| `AskConversationWindowController.swift` | 8 / 8 |
| `Local/AskAuxiliaryInference.swift` | 1 / 1 |
| `QuickResults/Plugins/Workflow/Editor/AskWorkflowAssistant.swift` | 2 / 2 |
| Protocol declaration and concrete conformance | 0 / 0 |

The denominator is added/modified physical production lines carrying LLVM `DA`
records, excluding comments, declarations without executable records, deleted
lines and tests. This is changed-line coverage, not whole-project or branch
coverage. `changed-coverage.txt` records the exact LLVM export command and line
counts; `changed-executable-lines.json` pins source hashes and individual line
numbers; `changed-files.lcov.gz` preserves raw hit counts and original `SF` paths.

```sh
python3 docs/validation/gul-456/changed_coverage.py --export
python3 docs/validation/gul-456/changed_coverage.py
python3 -m unittest discover -s docs/validation/gul-456 -p 'test_*.py'
```

Artifact-only recomputation also passed from a separate sparse Git checkout with
no `.build`, binary or profile copied (**0.306 s**); its `SF` paths still point at
the original checkout. See `artifact-portability.log.gz`. Four Python regressions
passed and cover foreign paths, path ambiguity/traversal, missing source records
and invalid/orphan executable records. The script rejects changed source hashes
or missing individual executable lines rather than silently reducing the denominator.

Production lint comparison uses the same root config against baseline copies and
current changed sources: **145 → 144 diagnostics**, **no added rule counts**;
both exit 2 because of existing repository errors. Test-file lint exits 0 with
24 warnings and no errors. Raw JSON/logs and timings are committed. `git diff
--check` passes. Existing file/body-length and style debt is not refactored here.
