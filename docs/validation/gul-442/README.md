# GUL-442: queued intent and task supplements

Follow-ups remain a FIFO queue within the current Mac session. Recovery, unknown state, approval, credits, device ownership and in-flight submissions block execution. Failed/cancelled runs retain intent and pause. Queue intent is not persisted or synced across devices.

Per-item claims preserve the exact draft/ID and reserve capacity until settlement. Normal Send queues a new turn; Add to current task targets the captured original run. Only authenticated transcript evidence confirms consumption. Display/cache messages cannot acknowledge a queued send or supplement. Explicit continuation retries the existing pending request: another failure restores and pauses it, while acceptance permits FIFO continuation.

The original head `6fd3140576b569f7edcd3019545e548a66151d51` was rejected by independent acceptance because a usage-only snapshot inherited an optimistic message and incorrectly acknowledged it. [Correction and caller audit](CORRECTION.md) records the fix and regression coverage. Earlier passing tests and coverage did not establish acceptance of that head.

## Final local validation

Base: `629013ece134908f15c0800a4ec084af4ff8bbaf` (accepted stage8 merge). Correction base: `6fd3140576b569f7edcd3019545e548a66151d51`. Swift 6.4, Xcode 27.1 (27A9275), arm64 macOS.

```sh
make coverage SUITE="AskSendQueueTests AskQueueOwnershipTests AskRunPhaseTests AskFolderAuthorityTests AskCommandJobLifecycleTests AskTemporaryConversationTests AskCreditPauseTests AskLocalSteeringTests AskScopedApprovalTests AskRecoveryNoticePresentationTests AskRecoveryWireTests AskBrowserSitePolicyTests AskAgentTurnTests" FILTER="AskAgentBindingInteractionTests/acceptanceStopAfterObserverPrecedesSendResponse"
```

**147 test methods passed: 25 XCTest and 122 Swift Testing. Complete command wall time: 27.32 seconds**, including incremental build/discovery and coverage export (runner subtotal 25.11 seconds; build 6.08 seconds). This was a verified incremental build following the first-use build below. One final binary/profile supplies both metrics; no historical-run profiles were combined.

| Scope | Behavior checked |
| --- | --- |
| Queue policy/ownership | FIFO, failed/cancelled pause, explicit continuation, unknown/receipt/credits/device gates, capacity, exact draft/ID, deduplication |
| Model integration | Held sends/steers, independent usage/recovery/budget updates, cache suspension, authenticated acceptance before response, late errors, edit/remove/clear/Stop/reset/account/delete/selection/replacement fences |
| Retry/routing | Cloud/local AskRoutedAPI paths; another failed retry retains both items and pauses; success reuses ID and continues FIFO; admitted recovery cannot replay into a replacement run |
| Compatibility | Real local engine supplement ordering, original-run identity, stage7 local cancellation versus durable retirement, stage8 folder admission and single-use mutation consent, temporary/kept conversations |
| Presentation | Shared run phase and affected existing small queue render fixture |

Changed product Swift executable-line coverage is **479/486 (98.56%)** against stage8. The correction alone is **37/37 (100%)**. These are unique LLVM LCOV DA line counters excluding blank/comment-only lines, not whole-project or branch coverage. The two coverage JSON files list every denominator and uncovered line. `source-sha256.json` records all 18 changed source/resource/test files.

Scoped SwiftLint across the model and three changed test files reports **45 existing errors, unchanged from the correction baseline**. The queue ownership test file has no lint errors. Structural warnings remain; full-file lint is not green. `git diff --check` passes. This correction changes no localization or UI markup.

Unexecuted product lines cover malformed successful send/retry response rejection, recovery-check capability refusal/cancellation and the stored Claim initializer counter. Live cloud/model services, full unit/UI suites, pixel-level UI QA and CI were not run.

## Recompute

Extract the attached correction evidence archive to `evidence/` at the repository root:

```sh
python3 docs/validation/gul-442/recompute_coverage.py evidence/coverage.lcov --output recomputed.json
python3 docs/validation/gul-442/recompute_coverage.py evidence/coverage.lcov --base 6fd3140576b569f7edcd3019545e548a66151d51 --output correction-recomputed.json
```

The script uses Python's standard library and Git, normalizing LCOV paths by `Sources/Typeflux/`. Compare source SHA-256 values against the manifest. `evidence/provenance.json` records the final binary/profile hashes, toolchain and exact command. `evidence/profiles/final.profdata` is the final process profile from that single focused run. To regenerate LCOV with its matching binary:

```sh
xcrun llvm-cov export \
  .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests \
  --instr-profile=evidence/profiles/final.profdata --format=lcov \
  Sources/Typeflux/Ask/AskConversationModel.swift Sources/Typeflux/Ask/AskQueueViews.swift \
  Sources/Typeflux/Ask/AskSendQueue.swift Sources/Typeflux/Ask/AskWorkspacePresentation.swift \
  Sources/Typeflux/Ask/AskConversationViews.swift Sources/Typeflux/Ask/AskAPI.swift \
  Sources/Typeflux/Ask/Local/AskLocalEngine.swift > evidence/coverage.lcov
```

## Self-review and intermediate results

Review covered entry-to-settlement behavior, empty/error paths, ownership after suspension, cancellation/attempt identity, reservation cleanup, idempotent retry, account/device isolation, selection/deletion fences, original-run association, folder/approval authority and documentation consistency. The correction separates raw confirmation from presentation and checks session/deletion after suspension. It also fixes explicit pending retry leaving following FIFO items paused; retry failure now restores the still-owned submission before operation cleanup.

The first focused run took **398.02 seconds** including first-use dependency preparation/build. Only the new two-item continuation assertions failed (8 parameter cases, 16 issues); intent-retention and positive cache confirmation checks passed. After the continuation fix, the queue suite took **86.49 seconds**: those cases passed, but a new recovery fixture incorrectly seeded an optimistic display transcript as server evidence (2 cases, 6 issues). The fixture was corrected to use API state. Its isolated retry passed in **72.51 seconds**, then the final 147-method scope passed on unchanged final sources in **27.32 seconds**. Failed/successful logs and exact command timings are retained. Swift builds/tests ran sequentially, with no source edits during execution.
