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

Checked complete command-to-local-engine and host tool/model paths, legacy/malformed decoding, Codable/source compatibility, async state reloads, owner/device/run checks, duplicate/late receipts, approvals, cache claims, usage, cancellation and localization across five languages. Added freshly loaded admission after tool preparation/approval and before model/tool IO, receipt retransmission and process cancellation. Stop now reads and admits the current run before host cancellation, so an unsupported task cannot falsely appear stopped. Unknown snapshots remain readable without expiry/recovery rewrites. No new screen, state, host port or adapter selection. Swift actor isolation is retained. `git diff --cached --check` passed. Raw runner logs, all wall timings, raw profiles, combined production profile and LLVM export accompany the issue evidence attachment.
