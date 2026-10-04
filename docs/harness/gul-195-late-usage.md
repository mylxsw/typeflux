# GUL-195: late local usage after retry

This repair starts from Swift main
`a4fd0bcf2bf5c55b8be89778f261ef00e1178294` (R01/R02/R05 already merged).
The API needs no changes or migration. The PR targets `main` independently of
the previous stacked branches.

## Settlement boundary

Each new local reservation records an optional invocation identity containing
the local owner, conversation, budget root, run and device. The reservation's
operation ID, call ID and kind remain part of the validation. Identity comes
from the engine's dispatch state, not the incoming receipt. Re-reserving an
existing operation cannot change its run or identity.

`inferenceResult` accepts only the local token boundary (an empty token).
`AskRoutedAPI` routes authenticated Cloud receipts to the Cloud backend. Local
conversations use the existing `local` owner, including private conversations
created while signed in. Memory source ownership is separate: deleting an
account's captured Memory neither changes the budget owner nor erases usage.

A late receipt for an earlier run in the retry's shared root first validates
the persisted reservation and settles through the existing locked, atomic
budget journal. Only a receipt matching the current waiting inference can
apply content or tools. An older receipt returns the current conversation with
its refreshed budget; it does not save stale messages, Memory, revision,
timestamps or run state. Async built-in completions also refresh the budget
on the latest conversation before returning after cancellation or replacement.

Retry still inherits the original root, limits and deadline. Client-reported
usage remains conservative: duplicate values do not increment accounting;
missing or partial usage never releases a pending reservation. No provider
finality or cost guarantee is inferred from a client receipt.

## Existing journals

The optional identity preserves decoding of v1 journals and the shared v1
fixture. When reading an older journal, the engine can fill identities only
for reservations whose stored run ID matches the currently persisted run;
that run supplies the device binding. This happens before retry replaces it.

If an earlier version already replaced the run before the upgrade, a historical
reservation with no device identity cannot be authenticated. Such receipts are
rejected and their conservative occupation is retained. The engine does not
reconstruct identity from receipt claims or Memory. It also does not search
unrelated budget roots or recreate deleted conversations to accept receipts.

## Regression evidence

Before the repair, the new cancel → retry → old usage regression failed at
`AskLocalEngine.swift:205` with the conversation-conflict error. The same test
then passed with no restart, restart before retry and restart after retry,
including duplicate receipt delivery after reopening the journal.

Additional regressions cover:

- Old receipts racing the new run's completion or cancellation; exact content
  and persisted state remain owned by the new run.
- Unknown operations, mismatched run/device/conversation, authenticated account
  routing, every persisted identity field, wrong operation kind and released
  reservations. Rejected receipts do not change journal accounting.
- Missing, failed and invalid usage, followed by late valid usage, with all
  unknown occupation retained.
- Legacy identity recovery before retry, and refusal to infer a lost historical
  device binding after retry.
- Budget-enabled Memory deletion while the new run's web request is suspended,
  old usage and duplicate receipts arriving during that suspension, completion
  or cancellation, and restart. Memory note tombstones, owner invalidation and
  the original budget journal survive; stale content/tools never run.

All model and web responses in these regressions are fixtures. No real model,
external MCP, cross-device session or interactive browser/computer permission
matrix was exercised; those remain R06 acceptance work. Worker, automatic
recovery, Memory/budget and other restricted capability defaults are unchanged.
This repair does not authorize replay of unknown effects, production enablement,
merging or advancement of R04.

## Validation on 2026-10-04

Environment: macOS arm64, Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), locked package
dependencies. All results below were collected on this delivery's source and
tests. The source did not change between the full test and coverage runs.

| Check | Result |
| --- | --- |
| New regression against unchanged main | Failed as expected: 1 test, conversation conflict before settlement |
| Same regression after repair | Passed, including all three restart positions |
| Affected suites | 39 tests passed, zero skips/failures |
| `swift test` | Exit 1: 2,811 XCTest cases, 5 skips, zero failures; 793 Swift Testing cases, one failing test with 4 assertions |
| `make coverage` | Exit 0: complete suite, 2,811 XCTest cases with 5 skips and zero failures; all 793 Swift Testing cases in 104 suites passed |
| Focused strict SwiftLint | Passed for the budget controller, budget integration and both changed test files |
| Whole-repository SwiftLint | Exit 2: 596 errors and 2,448 warnings |
| `git diff --check` | Passed |

The affected-suite command was:

```sh
swift test --filter 'AskLocalLateUsageTests|AskLocalBudgetTests|AskBudgetTests|AskLocalEngineReentrancyTests|MemoryProvenanceTests|AskRoutedAPITests'
```

The standalone full run failed
`AskAccountFooterClickTests.accountNameClickTogglesTheAccountCard` at lines 37,
39, 43 and 44 (visibility/pointer assertions). The subsequent complete coverage
run passed without changing product or test code. This is evidence of the
reported UI instability, not a claim that the flake was fixed. No independent
retest is substituted for either full-run result.

The five skips in both full runs were real Chrome, Safari and desktop permission
acceptance, the opt-in Memory removal-error screenshot, and the opt-in skills
settings screenshot. No skipped permission or snapshot test is counted as passed.

Coverage uses the repository's `llvm-cov` **line** metric and exclusion
`\.build|Tests`, from the successful complete `make coverage` profile:

| Production file | Covered / instrumented lines | Line coverage |
| --- | ---: | ---: |
| `AskBudgetController.swift` (modified) | 169 / 169 | 100.00% |
| `AskLocalEngine+Budget.swift` (modified) | 166 / 171 | 97.08% |
| `AskLocalEngine.swift` (modified) | 542 / 569 | 95.25% |
| Modified production files combined | 877 / 909 | 96.48% |
| `AskBudgetStore.swift` (unchanged dependency) | 28 / 29 | 96.55% |
| Whole source | 73,715 / 134,389 | 54.85% |

Every modified production file exceeds the 90% line target and the requested
80% threshold. These percentages do not claim equivalent function or branch
coverage. Whole-source coverage remains below both thresholds; the main branch's
full coverage was not rerun in this issue, so no measured baseline delta is claimed.

The remaining 48 LocalEngine lint diagnostics were checked against the actual
main source with the same configuration (50 diagnostics there). The reentrancy
test's existing long-line diagnostic was removed (1 → 0), and the other changed
Swift files have none. This narrows the changed-file lint debt but does not make
whole-repository lint clean. Compiler warnings in existing code also remain.

API tests and database migrations were not run because this is a Swift-only
repair. The API main snapshot supplied by the coordinator is dependency context,
not a test result produced by this task. Human review of this fixed Swift
delivery and subsequent R04/R06 combination evidence are still required.
