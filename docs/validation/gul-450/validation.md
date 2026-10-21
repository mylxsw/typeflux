# GUL-450 Swift validation

Based on main `3f8e583a`; the prerequisite is an ancestor. The intervening draft screenshot projection change remains intact. Increment A only: no alternate engine, picker, adapter registry or client cloud selection.

## Scope and results

Focused command:

```sh
make coverage SUITE="AskAgentBindingTests AskAgentBindingInteractionTests AskHarnessContractTests AskLocalEngineTests AskLocalEngineReentrancyTests AskLocalBudgetTests AskLocalLateUsageTests AskLocalUsageTests AskLocalSteeringTests AskLocalApprovalTests AskRoutedAPITests AskLocalModeIntegrationTests AskLocalWebToolsTests TypefluxCloudServerErrorMessageTests AskConversationTests AskRecoveryInteractionTests"
```

Total wall time **211.82 s** (includes build/discovery; test execution phase 15.35 s). Executed **69 XCTest cases and 58 Swift Testing cases**. No skips. All 58 interaction/recovery cases passed. Two XCTest methods initially failed: a new full-snapshot equality assertion and an existing typed image-receipt assertion. All selected cases now have passing results after the focused retries below; no unresolved test failure.

The new snapshot test was comparing `JSONValue` raw object bytes through synthesized Equatable; object-key ordering caused false inequality. Use deterministic epoch time and compare complete sorted encoded JSON instead; after every rejected command the original persisted bytes must still match exactly. First two-method retry, `make coverage FILTER="AskAgentBindingTests/testUnsupportedCommandsLeaveSnapshotAndUsageIntact|AskLocalEngineTests/testLegacyReopenedTypedReceiptPreparesWithoutRepeatingTool"`, took **101.88 s**. The image-receipt method passed (0.248 s execution) without production/test changes; its initial failure followed a 3-second media-worker timeout. Snapshot comparison still failed before the key-order correction. Final retry only `make coverage FILTER="AskAgentBindingTests/testUnsupportedCommandsLeaveSnapshotAndUsageIntact"` passed in **78.69 s** wall time (0.126 s test execution).

An earlier runner preparation took **473.72 s**, including first-use build (432.89 s), but executed no tests because the requested `AskLocalModeTests` suite name did not exist. Corrected to its actual three suite declarations above. This was normal SwiftPM test-target compilation, not full test execution. All failed preparation/retry logs are retained.

Mapping: binding tests exercise shared JSON fixtures, persisted Send/Retry/Regenerate identity, legacy no-backfill, status/command rejection and stable localized errors; local engine/budget/late-usage/steering/approval/reentrancy suites cover direct continuations and suspension; routing/local-mode tests cover affected callers; conversation/recovery interactions cover fresh host reloads, tool/model admission, approval reload, host cancellation and saved receipts. Shared fixture manifests are checked and fixture bytes match Go.

## Coverage

Changed executable Swift lines: **130/137 = 94.89%**. Denominator: added/modified production lines intersecting counted LLVM segments (gap/non-counted regions excluded); tests and resources excluded. Full focused pass and retry profiles are combined for unchanged production code. Test-module counters are excluded from merged output. LLVM reports a counter-layout mismatch in the edited test assertion closure; that test-only function is not part of this production-line metric (see `profile-merge.log`). Production functions were unchanged across passes. See `changed-code-coverage.json` for per-file counts and exact uncovered lines. This is not project-wide coverage; the final single-method HTML report alone is not the combined coverage evidence.

Uncovered changed paths: stored run failure localization projection, cross-device unsupported host-drive branch, queued-message steering admission, wrong-run Resume rejection, summary-after-suspension guard and late summary finalization admission. Full UI/unit scope, real external model/tool services, alternate adapters and negotiated old-binary ownership are not verified or enabled. No GitHub CI result is claimed.

## Self-review

Checked complete command-to-local-engine and host tool/model paths, legacy/malformed decoding, Codable/source compatibility, async state reloads, owner/device/run checks, duplicate/late receipts, approvals, cache claims, usage, cancellation and localization across five languages. Added freshly loaded admission after tool preparation/approval and before model/tool IO, receipt retransmission and process cancellation. The original stop ordering was superseded by the ownership-aware cancellation correction below. Unknown snapshots remain readable without expiry/recovery rewrites. No new screen, state, host port or adapter selection. Swift actor isolation is retained. `git diff --cached --check` passed. Raw runner logs, all wall timings, raw profiles, combined production profile and LLVM export accompany the issue evidence attachment.

## Architecture review correction (2026-10-21)

Stop now captures the account, conversation, run and operation ID on the main actor. Host work is interrupted synchronously only when the owned operation scope matches that identity, and only that project run is cancelled. Its grants and pending approval are revoked before any network read. Unsupported snapshots cannot authorize control of another run through an old handle. Network reads and remote cancellation remain separate: captured and refreshed bindings must both be supported, the captured identity must still match, and a delayed response cannot overwrite another account or a replacement run. Local interruption does not claim remote completion after an unsupported/failed read.

Per-operation run scopes are registered after execution admission, removed when the operation finishes, and reset with the session. Self-review checked the complete cancellation path, stale snapshots/handles, post-suspension account and run identity, grant revocation, partial inference handling, pending approval release, actor isolation, and scope cleanup. Cancellation targets a captured run rather than conversation-wide processes. No lifecycle policy or permission behavior outside Stop changed.

Focused command:

```sh
make coverage SUITE="AskAgentBindingInteractionTests AskConversationTests AskScopedApprovalTests AskRecoveryInteractionTests"
```

Total command wall time **570.85 s**, including first-use dependency resolution, full test-target compilation/build (**532.45 s**), discovery and execution. Only the selected **53 Swift Testing methods in four suites** executed; no full unit/UI test execution and no skips. Stop's legacy/default/unsupported/throwing suspended-read cases passed, as did unknown-run ownership boundaries and existing conversation, scoped approval and recovery callers. The replacement-work method's account and run parameters failed because the setup did not reselect a conversation after reset and left permission mode at Stop's reset default. Those setup issues were corrected without production changes.

Only the failed method was retried:

```sh
make coverage FILTER="AskAgentBindingInteractionTests/delayedStopCannotCancelReplacementWork"
```

Passed both parameters in **80.60 s** total wall time, including rebuild/discovery/coverage rendering. All 53 selected methods now have passing results; no unresolved failure. Tests assert owned operation completion and grant removal before releasing a suspended read, no remote cancellation or false stopped status on read failure/unsupported binding, no cancellation of replacement work across an account/run switch, and no authority over an unknown run from a mismatched old handle.

Correction-only changed executable-line coverage is **32/32 (100%)**, relative to PR head `fbbcc0c4`, intersecting added/modified production lines with counted non-gap LLVM segments. This is line coverage, not branch coverage or project-wide coverage. The initial failed test command left raw profiles instead of `default.profdata`; these were merged manually with `xcrun llvm-profdata merge -sparse` and exported before the test-only fix. The failed attempt to copy nonexistent default.profdata was preparation only and ran no tests. Both initial and retry profiles/LLVM exports are preserved, avoiding counter-layout mismatch from merging changed test functions. The production file was identical across both runs. See `review/changed-coverage.json` and the new issue evidence attachment for raw logs, profiles and timing.

`git diff --check` passed. Existing compiler warnings are retained in raw logs. External services/adapters and GitHub CI results remain unclaimed; no CI wait or merge was performed.


## Pre-admission Stop correction (2026-10-21)

This section supersedes the previous correction's admission-only ownership rule. The architecture owner's first-submission reproduction is retained as `acceptanceStopBeforeRunAdmission` and passes. Go PR #153 is accepted and merged; this correction updates Swift PR #690 only.

Local ownership is registered synchronously with Task creation for model preflight, Send, Retry, Regenerate and credit Resume. It records the account and original optional run, keyed by the conversation's operation generation, separately from its admitted run scope. Stop cancels matching owned work and revokes approvals immediately even with a nil run or suspended preparation/dispatch. Project-tool cancellation requires an admitted matching scope. Pre-admission cancellation does not fetch a new run to cancel remotely. Pending request evidence remains available when dispatch outcome is unknown.

Admission, response handling and operation-owned observers validate cancellation and generation; a late response cannot enter drive, overwrite a replacement operation or start recovery/model/tool work. The latest generation remains after task completion to fence delayed Stop responses; active ownership/run scopes clear on completion, replacement, temporary discard and session reset. Quick Ask delegates both its optimistic-conversation and preflight Stop paths through the same ownership checks. Existing account/run/binding checks still gate remote cancellation. Local Task cancellation never reports remote success.

Final self-review found a further suspension window inside `accept`: cache/workspace persistence could finish after cancellation and publish the old response. Added cancellation and optional operation validation before acceptance and after persistence, with a deterministic gated-cache regression. That test deliberately lets the cache ignore cancellation until released and verifies that the response is not published. All affected driver and observer acceptance calls carry their operation generation.

### Local commands and results

```sh
make coverage SUITE="AskAgentBindingInteractionTests AskConversationTests AskScopedApprovalTests AskRecoveryInteractionTests AskQuickAskTests AskModelSelectionTests"
```

**97 methods in six suites passed**, no skips. Total command wall **570.04 s**, including first-use dependency checkout/build (**529.83 s**), discovery, execution and coverage rendering. Swift Testing execution: 9.219 s. New parameterized cases cover preflight/preparation/send cancellation without releasing the gate, same-turn Retry/Regenerate/Resume, account/operation replacement and Quick Ask. Existing admitted-run, unsupported-run, suspended-read, approval and recovery cases also passed. Initial correction coverage was 89/105 (84.76%), so only uncovered command callers were supplemented:

```sh
make coverage FILTER="AskRegenerateTests/(regenerateReplacesTheAnswerInsteadOfAskingAgain|regenerateSurfacesFailuresWithoutLosingTheAnswer)|AskCreditPauseTests/(continueResumesThePinnedRunAndFinishesIt|stillEmptyBalanceKeepsThePauseAndRefreshesTheAccount|otherResumeFailuresAreReported)|AskTemporaryConversationTests/endingFromTheHeaderNeedsNoConfirmation"
```

**Six methods passed**, no skips, **44.84 s** wall including reusable-build verification (**27.60 s**); test execution 0.187 s. Coverage reached 101/105 before the final persistence correction. After that code/test change, only the affected cancellation/conversation scope and direct Quick Ask Stop caller were revalidated:

```sh
make coverage FILTER="AskAgentBindingInteractionTests|AskConversationTests|AskQuickAskTests/stopDelegatesBeforeRunAdmission"
```

**37 methods in three suites passed**, no skips, **285.21 s** wall including incremental rebuild (**246.25 s**); test execution 4.396 s. No failed tests or failed build/runner attempts in this correction. The final persistence test passed in 0.124 s. No full unit/UI execution, external model/tool services, GitHub CI wait or merge.

### Final changed-code coverage and limits

**110/115 = 95.65%**, relative to `313c80e8b125ba94d79c2c223f475b91bcd80dda`. Denominator: unique counted LLVM LCOV DA lines intersected with added/modified production Swift lines; tests/resources excluded. This includes executable delimiters LLVM reports and is line coverage, not branch or project-wide coverage. Initial, supplement and final profiles are merged against the final binary. The new `accept` signature is covered by the final pass only; unchanged function counter layouts are reused, with no merge diagnostics. Raw per-pass profiles/exports and final merged LCOV/JSON, binary/source hashes, command logs, timings and correction patch are attached to the issue. See `pre-admission/changed-coverage.json` for the exact denominator and counts.

Uncovered changed lines: legacy nil-run Resume reconstruction's pre-send check; the new operation argument on drive's budget-expiry acceptance; registerOperation's takeover of an existing preflight reservation. The replacement regressions exercise completed/reset operation generations and late Stop fencing, rather than that reservation-takeover branch. These paths were self-reviewed but are not claimed tested by this correction. Actual external remote cancellation/completion, network transport abort guarantees, full UI behavior and alternate engines remain unverified. A transport that ignores cancellation may return later; the tests verify cancellation is observed before gate release and the late result cannot continue the cancelled operation.

Deep self-review checked the complete submission-to-drive chain, nil-run/unsupported/mismatched run boundaries, owner and operation fencing after awaits, grants/approval release, observer admission, late errors, pending-request evidence, scope cleanup, actor isolation and documentation. Fixed the persistence-window issue found during this review and verified it with the gated-cache regression. No new dependency, permission, localization string, screen or broad process cancellation. `git diff --check` passed. Architecture and final acceptance remain with Arch/GPT-Astra.
