# R04 validation

GUL-183 validation on 2026-10-04 uses Swift main
`5ec2bf5a5d70f4ed0bc38bdc02348c997e1d2b6c` (GUL-195 and GUL-193 included), plus
this branch's recovery implementation. The API target is main
`981d226bc09829026851675b5498a843a33792a9`; the test-only companion is
[#106](https://github.com/mylxsw/typeflux-api/pull/106) at
`ba930457608fd760b66d74d6b379bdfc717d6bcb`. Neither PR enables production features.
The tested Swift implementation is `1366d2c6dd7d63c09e334c4ad1cf360f0797b29a`;
subsequent changes contain only this report, documentation and view captures.

## Swift checks

- Final `make coverage` runs the full `swift test --enable-code-coverage`: 2,813
  XCTest cases, 5 skips, zero failures; 823 Swift Testing cases with one failing
  account-card click test (four assertions). The command exits 2. All recovery
  suites pass; the same four assertions fail on clean integrated main below.
- Integrated targeted recovery/HTTP/conversation/model/local-engine/budget/Memory/
  reasoning/effort/hover regression passes: 29 XCTest cases (1 skip) and 110 Swift
  Testing cases. It does not substitute for the failed full-suite gate.
- Production, test and localization source hashes were unchanged throughout this
  final full run. The final documentation commit does not change those sources.

The five XCTest skips are three opt-in real automation acceptance cases and two
unrelated opt-in settings snapshot cases. They are not counted as successful
acceptance. Recovery rendering runs in the full suite; final integrated PNG capture also
uses `TYPEFLUX_RECOVERY_SCREENSHOTS` in the targeted run.

Covered behaviors include:

- Real SQLite migration from the old schema, claim/receipt transaction failure,
  concurrent claim exclusion, immutable saved receipts, deletion tombstones,
  and retention when an old writer issues its pre-R04 deletion SQL.
- Two real child-process SIGKILL boundaries: after claim and after receipt
  commit. Reopening the production cache preserves the original identity and
  cannot authorize another dispatch. All child PIDs are reaped by the test.
- Tools and custom inference completing before HTTP delivery fails, then
  client/model/cache reconstruction and receipt-only resending with no executor,
  model-provider or approval invocation.
- Unknown claims, inspect/end/new-request actions, blocked ordinary retry,
  regenerate, queue resume and steering, unreadable journals, different devices,
  account switching/logout during suspended reads, and failed cancellation.
- Frozen R03 wire fixtures, legacy statuses, malformed/future metadata and
  statuses, opt-in HTTP/SSE headers, stale SSE and independent usage/recovery
  clocks, local engine restart, old-run metering and sticky Memory purge.
- Native SwiftUI light/dark recovery cards and inspector fixtures, with model
  action/state tests. These are not claims of successful native AX button event
  automation; that dispatch was unreliable in this host.

## Coverage and baseline

Coverage is LLVM executable-line coverage, excluding `.build` and `Tests`, from
the full instrumented suite. Core totals sum covered/executable lines, not an
average of file percentages. Core comprises the eleven production files listed
below; UI files are reported separately.

| Core file (under `Sources/Typeflux/Ask`) | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| `AskAPIClient.swift` | 122 / 130 | 93.85% |
| `AskConversation.swift` | 161 / 162 | 99.38% |
| `AskConversationCache.swift` | 129 / 140 | 92.14% |
| `AskConversationModel.swift` | 1,643 / 1,754 | 93.67% |
| `AskConversationStream.swift` | 59 / 59 | 100.00% |
| `AskTypedContent.swift` | 177 / 183 | 96.72% |
| `AskUsage.swift` | 165 / 171 | 96.49% |
| `Local/AskLocalEngine.swift` | 544 / 580 | 93.79% |
| `Recovery/AskConversationCache+Execution.swift` | 107 / 107 | 100.00% |
| `Recovery/AskConversationModel+Recovery.swift` | 165 / 167 | 98.80% |
| `Recovery/AskRecovery.swift` | 110 / 112 | 98.21% |

**Modified core: 94.87% (3,382/3,565); new recovery core: 98.96% (382/386).**

UI is separate: `AskRecoveryViews.swift` 97.91%, `AskWorkspacePresentation.swift`
96.88%, and the existing `AskConversationViews.swift` 82.00%. Combined modified UI
is 83.96% (2,486/2,961), below 90%; this is not reported as a passing UI target.

All source: **55.27% (74,971/135,644)** versus **54.99% (74,116/134,783)** on
clean integrated main. Both final runs completed their test cases but failed the
same account-card assertions. Their LLVM reports were extracted from both raw
XCTest and Swift Testing profiles after the coverage script exited; these
measurements do not turn the failed test gates into passes.

The earlier clean `e5135cc6` baseline was also run in this task: `make coverage`
passed, with 2,811 XCTest cases (5 skips), 793 Swift Testing cases and 54.84% all
source coverage. After #283 landed, the clean `5ec2bf5a` baseline was rerun:
XCTest passed, while 803 Swift Testing cases had four assertions fail in the
existing `AskAccountFooterClickTests.accountNameClickTogglesTheAccountCard`.
Its instrumented all-source coverage is 54.99% (74,116/134,783), extracted by
merging both emitted raw profiles after `make coverage` stopped at those failures.
That is a measured baseline, not a green baseline gate.

An earlier R04 full run also exposed the existing account hover test's 3-second
poll timeout while concurrent native rendering occupied MainActor. This branch
raises only that test's bounded wait to 15 seconds, retaining all assertions and
production delays. Account-card event-delivery flakiness is not declared solved.

## Lint and self-review

Strict SwiftLint passes for the four new recovery source files, four new recovery
test files and the adjusted hover test. Whole-repository lint remains red:
clean `5ec2bf5a` has 3,056 findings (596 errors, 2,460 warnings); this branch has
3,064 (594 errors, 2,470 warnings). The increment is not hidden as a passing gate.
`git diff --check` passes. Self-review checked original account/device/run binding,
the pre-dispatch claim and pre-delivery commit ordering, duplicate receipt
behavior, stale snapshots, tombstone retention and default-off configuration.

## API combination

The companion API PR adds only tests, a required gate entry and its report.
Against PostgreSQL 16.15 in a fresh isolated container:

- 36 required PostgreSQL tests pass with `-race`, zero skips. Existing coverage
  includes four real worker process-kill phases, mixed-version, rollback and
  transaction-failure tests.
- The added three-path test combines reasoning levels with receipt-only resume,
  cancel/retry, regenerate, late/duplicate original-budget settlement and Memory
  purge after engine/store reconstruction. Custom `max` maps to cloud `high` when
  changing to the narrower model; retry keeps the root, regenerate uses a new one.
- Full `go test -count=1 ./...`, `go vet ./...`, and Ask/handler/modelcatalog race
  checks pass. Ask coverage is 94.8%, all internal 85.1%: the approved 80% floor
  passes and strict 90% fails. The existing whole-repository ASR race was not
  rerun or fixed.

The old `ee888910` 35-gate run was performed earlier in this task but is not used
in place of the latest API results. The R03 fixture remains byte-identical. The
isolated PostgreSQL container was stopped after validation.

## Remaining acceptance and rollback limits

Real provider/MCP calls, a live Swift-to-API session, multiple physical devices,
the full browser/computer permission matrix and full GUI application SIGKILL
remain unverified. The subprocess test proves SQLite journal durability, not
whole-app survival. D02 still does not guarantee Python orphan cleanup after
host SIGKILL; no local task is promised to continue after app exit. Screenshots
use synthetic fixtures in real native recovery views.

Remote unknown outcomes expose inspection and cancellation only. No resolution
endpoint or remote operation evidence is invented. A user may type a fresh
request after ending the run; ordinary retry and missing receipts never grant
permission to replay an unknown side effect. Existing journals and tombstones
remain on rollback/deletion. Automatic recovery, worker, new protocol metadata,
Memory/budgets and previously restricted capabilities stay default-off.

Human acceptance and production enablement remain separate from PR delivery.
