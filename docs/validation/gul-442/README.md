# GUL-442: queued intent and task supplements

Follow-ups remain a FIFO queue within the current Mac session. Automatic advance and explicit continuation share a pure disposition policy. Recovery, unknown state, approval, credits, device ownership and in-flight submissions block execution. Failed/cancelled runs retain intent and pause; queue continuation opens existing recovery actions without ending an unresolved run.

Per-item claims retain the exact draft/ID, revision, epoch and capacity reservation. Owned attempts reconcile account/session/device/run identity after suspension. Removing/clearing intent cancels local work and prevents replay, while authenticated consumption releases its reservation. Selection changes preserve confirmed evidence without activating or advancing another conversation. Queue intent clears on session reset and is not persisted or synced across devices.

Normal Send queues a new turn. Add to current task targets the captured original run. Accepted supplements remain separate until an authoritative transcript ID confirms consumption. A local engine regression also required saving the accepted answer/supplement boundary before requesting its next adapter decision; the existing state/revision/owner checks remain intact.

## Final validation

Base: `629013ece134908f15c0800a4ec084af4ff8bbaf` (accepted stage8 merge). Swift 6.4, Xcode 27.1 (27A9275), arm64 macOS.

```sh
make coverage SUITE="AskSendQueueTests AskQueueOwnershipTests AskRunPhaseTests AskFolderAuthorityTests AskCommandJobLifecycleTests AskTemporaryConversationTests AskCreditPauseTests AskLocalSteeringTests AskScopedApprovalTests AskRecoveryNoticePresentationTests AskRecoveryWireTests AskBrowserSitePolicyTests AskAgentTurnTests" FILTER="AskAgentBindingInteractionTests/acceptanceStopAfterObserverPrecedesSendResponse"
```

**144 test methods passed: 25 XCTest and 119 Swift Testing. Total command wall time: 42.04 seconds**, including 29.04 seconds of build/discovery. This final run used one binary/profile and all final source files. It supersedes intermediate coverage reports; no profiles were combined for the final metric.

| Scope | Evidence |
| --- | --- |
| Queue policy and ownership | Known/unknown/malformed states, blockers, FIFO, old/equal terminal observations, explicit continuation, capacity reservations, exact-draft retention and deduplication |
| Async model integration | Deterministic held sends/steers, authenticated acceptance before response, late transport errors, edit/remove/clear/Stop/reset/account/delete/selection changes, replacement runs and discarded intent |
| Shared routing | Local/cloud fixture routing through existing AskRoutedAPI; real local engine supplement ordering after tool receipts and during inference |
| Compatibility | Adapter state/binding checks, local command cancellation versus durable retirement, folder admission before old-run retirement, fresh mutation consent, credits, recovery and temporary/kept conversations |
| Presentation | Shared run phase, pending supplement label and affected existing hosted queue render fixture; all six queue labels present in all five languages; all five strings files pass `plutil -lint` |

Changed product Swift executable-line coverage is **450/461 = 97.61%**, excluding blank/comment-only lines and using unique LLVM LCOV DA counters. This is focused changed-code coverage, not whole-project or branch coverage. The engine correction is **1/1**. `changed-line-coverage.json` lists every denominator line and uncovered line; `source-sha256.json` records all 17 changed source/resource files.

Scoped SwiftLint retains **16 pre-existing errors versus 17 at the baseline**: queue/model scope 10 versus 11, engine scope 6 versus 6. The new test file has no lint errors. Structural warnings remain; full-file lint is not claimed green. `git diff --check` passes.

The final scope leaves malformed successful-response identity rejection, refusal of recovery-check support, and a second transport failure during explicit pending retry unexecuted. LLVM also attributes zero hits to the stored Claim attempt initializer line; it remains in the denominator. Live cloud/model services, a full unit/UI suite, pixel-level UI QA and CI were not run.

## Recompute

Extract the attached evidence archive to `evidence/` at the repository root, then run:

```sh
python3 docs/validation/gul-442/recompute_coverage.py evidence/coverage.lcov --output recomputed.json
```

The script needs Python's standard library and Git. It compares final source against the accepted base and intersects added product Swift lines with normalized LCOV records. Compare source SHA-256 values against the manifest. The final raw profile is `profiles/final.profdata`; its matching test-binary hash and exact toolchain are recorded in `provenance.json`. To regenerate LCOV after a fresh focused coverage run:

```sh
xcrun llvm-cov export \
  .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests \
  --instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata --format=lcov \
  Sources/Typeflux/Ask/AskConversationModel.swift Sources/Typeflux/Ask/AskQueueViews.swift \
  Sources/Typeflux/Ask/AskSendQueue.swift Sources/Typeflux/Ask/AskWorkspacePresentation.swift \
  Sources/Typeflux/Ask/AskConversationViews.swift Sources/Typeflux/Ask/AskAPI.swift \
  Sources/Typeflux/Ask/Local/AskLocalEngine.swift > evidence/coverage.lcov
```

## Review and intermediate failures

Self-review checked transition closure, empty/error paths, attempt identity and cancellation, ownership after every await, retained capacity, replay prevention, account/device boundaries, folder/approval authority and localization. Review fixes include premature nonqueue acknowledgement, date-precision comparison, late callback resurrection/error reporting, cancellation after acceptance, discarded-request replay, and stale-account advancement. No wire status/decoding, backend scheduler or durable queue was introduced.

The first build hit a Swift compiler assertion around a shadowed caught error; explicit property access fixed it. Initial test preparation found mutating calls inside `#require` and a suite/file-name mismatch. The first 141-method execution had three failing Swift Testing methods (11 issues) and one failing local-engine XCTest method. Model ownership and response checks were corrected with smaller focused retries. The local-engine failure was initially missed in the XCTest section, then reproduced during contract regression: the next adapter decision compared an uncommitted cursor with persisted state. Saving the existing safe boundary fixed it; all four local steering and nine adapter methods passed before the final combined run.

Raw logs retain failed and successful attempts. Only the final combined run supplies the published coverage/profile. Earlier command timings are in `attempts.json`; intermediate source revisions were not committed and are not represented by the final source manifest. The standalone build retry reported 52.77 seconds internally; its complete command wall time was not recorded. Every Swift build/test ran sequentially, with no source edits during test execution.
