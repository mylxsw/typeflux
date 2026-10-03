# Local Ask memory purge during built-in tools

GUL-169 fixes a stale snapshot write in `AskLocalEngine`. While `web_fetch` was
suspended, `purgeMemory` could successfully clear and persist the conversation's
memory. The returning tool then copied only the latest revision and steering
queue into its old record, restoring the deleted memory in the next save.

## Merge invariant

Built-in execution returns a result delta: receipt text, error status, and an
optional validated plan. It cannot mutate or return a conversation snapshot.
Before execution, the engine persists the pending call and all preceding changes,
including any device receipt or earlier plan update. After execution, it:

1. Requires the conversation to still exist.
2. Checks the original run ID, running status, and first pending call ID.
3. Uses the current stored record as the write base.
4. Applies only the tool delta, removes the pending call, and advances the budget.

This is the equivalent of a deletion barrier for memory: no field from the
pre-suspension snapshot can restore it. It also preserves queued steering,
monotonic revisions, and `update_plan` changes without introducing a new
generation field into the persisted schema. Cancelled, expired, and replaced
runs retain their current state. A deleted conversation returns the existing
not-found error instead of returning its old snapshot.

## Suspension audit

| Path | Persistence after suspension |
| --- | --- |
| `continueTools` / `executeBuiltin` | Web execution is the external suspension point. Results now merge into the current record after identity and pending-state checks. |
| `send`, `result`, `inferenceResult`, `retry`, `regenerate` | Tail-return the step/completion/tool result; no additional snapshot write after it returns. |
| `applyCompletion` | Saves a synchronous completion or tail-returns the next step/tool result. |
| `step`, `queue`, `cancel`, `steer`, `purgeMemory`, storage helpers | Their actor-isolated work has no external suspension between reading and saving a record. |

## Regression coverage

`AskLocalEngineReentrancyTests` intercepts URLSession requests with a separate
gate for each test URL. The test waits until a real `web_fetch` is suspended,
performs the intervening engine operations, then releases headers and body. No
timing sleeps or external network/model requests determine the ordering.

- Six purge/fetch repetitions cover enabled/disabled memory and HTTP failure,
  returned/read/reopened state, prompt contents, and duplicate inference receipts.
- Both purge/steering orderings cover plans before and after fetch, deferred
  steering delivery after a device receipt, and the persisted built-in budget.
- Both purge/cancel orderings keep committed plans and exactly one receipt per
  call, while preventing subsequent pending plans from executing.
- Cancel/retry preserves the replacement run when the old fetch completes.
- Deletion prevents a late fetch from returning or recreating the conversation.

## Compatibility and scope

No public DTO, API, dependency, JSON schema, or feature flag changes. Existing
conversation files remain readable. This change covers local engine state
merging; explicit memory-store durability is owned by GUL-170. Tests use real
temporary JSON files and the local engine, with stubbed web responses and model
receipts. Live model behavior and interactive desktop operation are not verified
by these regressions; PostgreSQL is not used by this path.

## Validation on 2026-10-03

Base: `41d207accecf2f33583be670ead46cf60d32769b` (`main`). Environment:
macOS 26.6.2, Apple Swift 6.4, default `swiftbuild` backend.

- Unmodified baseline `swift test`: 2,547 XCTest and 557 Swift Testing tests
  passed (3,104 total).
- Before the production fix, the five new regression tests produced three
  failing tests / 31 expected assertions; cancellation and replacement-run
  cases passed. The six ordered fetch/purge repetitions consistently restored
  memory on the old implementation.
- After the fix, `swift test --enable-code-coverage --filter
  'AskLocal(Engine|Steering)'`: 16 tests passed.
- Final `make coverage`: its full `swift test --enable-code-coverage` phase
  passed 2,552 XCTest and 557 Swift Testing tests (3,109 total), with no failures
  or reported skips. The report phase then failed because `scripts/coverage.sh`
  searches for `TypefluxPackageTests.xctest`, while Swift 6.4's default backend
  produces `TypefluxTests.xctest`. The commands below generated the report from
  that successful run's `default.profdata`; no tests were excluded or rerun to
  construct these final coverage numbers.
- `git diff --check` and SwiftLint for the new regression file passed.

LLVM source-based coverage, excluding `.build` dependencies and tests:

| Scope | Before fix | After fix |
| --- | --- | --- |
| All 343 reported source files: lines | 61,802 / 122,680 (50.38%) | 61,849 / 122,688 (50.41%) |
| `AskLocalEngine.swift`: lines | 452 / 470 (96.17%) | 460 / 478 (96.23%) |
| `AskLocalEngine.swift`: regions | 269 / 297 (90.57%) | 271 / 299 (90.64%) |
| Changed functions `continueTools` + `executeBuiltin`: lines | — | 46 / 46 (100%) |
| Changed functions: regions | — | 22 / 22 (100%) |

The before-fix coverage invocation included the new regression tests. Unlike
the clean ordinary baseline above, it also encountered six existing
`StdioMCPClientTests` timeouts and failures in
`accountNameClickTogglesTheAccountCard` and
`dismissalFinishesAndLateCaptionsCannotReopenTheWindow`. All passed in the final
full run without modifying those tests or their implementation. The baseline
comparison includes that variability; the full-source percentage is not a
claim that all pre-existing modules meet the 90% changed-module target.

Report commands for this toolchain, after the successful test phase:

```sh
ASK_TEST_BINARY=.build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests
ASK_COVERAGE_PROFILE=.build/out/Products/Debug/codecov/default.profdata
xcrun llvm-cov report "$ASK_TEST_BINARY" --instr-profile="$ASK_COVERAGE_PROFILE" \
  --ignore-filename-regex='\.build|Tests'
xcrun llvm-cov show "$ASK_TEST_BINARY" --instr-profile="$ASK_COVERAGE_PROFILE" \
  --format=html --output-dir=coverage-report --ignore-filename-regex='\.build|Tests'
```
