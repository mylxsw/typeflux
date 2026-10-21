# GUL-454 C2 validation

Baseline: main at `17f06a87680a968f4c33dc81c3f3973a2ab316f7` (accepted C1).
Environment: Apple Swift 6.4, arm64 macOS; exact version in `environment.log.gz`.

The local engine now retains one `AskBuiltinToolHosting` instance for both
advertisement and execution. The default host owns the existing plan/history/web
implementation and budgeted session cloning/redirect refusal/invalidation. The
plan schema/parser lives in `AskBuiltinPlan`; engine static helpers delegate to
it. Existing `webTools:` callers and production factories keep the default host.
No Go code, selector, public authorization endpoint or UI wording changed.

## Focused execution

Commands ran from the repository. Wall times include dependency preparation,
compilation, discovery, runner startup, execution and coverage reports. Coverage
replaces a plain test pass. No full test/UI suite, CI wait or real provider request
was run.

1. `/usr/bin/time -p make coverage SUITE='AskBuiltinToolHostTests AskLocalEngineTests AskLocalEngineReentrancyTests AskSemanticCompactionTests AskLocalBudgetTests AskLocalWebBoundaryTests AskApplicationAPITests AskAgentBindingTests'`
   - Exit 0; **66 selected methods passed** (55 XCTest + 11 Swift Testing).
   - Total wall **422.27 s**, runner 416.63 s; first-use build 388.75 s,
     preparation/build/discovery 407.07 s. This checkout initially had no `.build`.
   - The five injection methods ran here. Default parity/transport methods were
     split into a test extension file during dependency preparation, after
     SwiftPM had enumerated sources. They were absent from this first inventory;
     the next command executes exactly those three missing methods.
2. `/usr/bin/time -p make coverage FILTER='AskBuiltinToolHostTests/(testDefaultDefinitionsAndPlanParity|testDefaultHistoryUnavailableAndWebFailureParity|testBudgetedSessionCopiesMockTransportAndCleansUpOnSuccessAndFailure)'`
   - Exit 0; **3 selected methods passed**.
   - Total wall **90.29 s**, runner 85.35 s; preparation/build/discovery 80.21 s.
     Incremental rebuild/discovery included the new extension file; this was not
     a verified cache hit or a repeat of the first 66 methods.

Together these provide **69 distinct passing methods**, with no failed-test
retry. Production source was identical for both instrumented builds.

The scope maps directly to the changes:

- Eight new host methods cover definitions/order, plan valid/invalid parsing,
  history valid/invalid results, unknown/unconfigured/fail-closed web tools,
  configured mock search success/failure, copied session configuration, redirect
  delegate refusal and ordinary source-session reuse after budgeted calls.
- Recording-host integration covers the actual approval/result entry point,
  immutable admitted snapshots, budgeted flag, delta/receipt application once,
  duplicate inference and approval receipts, denied approval, device-owned name
  collision, unsupported binding, exhausted web budget and the engine's 16-call
  limit with plan/history exemptions. The same fake handles definitions and
  execution; definitions are read once at run preparation.
- A held fake exercises purge alone, purge/cancel and purge/cancel/replacement.
  Late output cannot change winning ownership, content, plan or purged memory.
  Original-root reservations still settle once; the test explicitly permits the
  existing budget-summary refresh while checking unchanged winning state.
- Existing local engine, reentrancy, budget, semantic history, web boundary and
  binding suites cover their unchanged shared paths. Application API tests cover
  default factories and routing; the production conversation-factory check now
  also confirms the retained concrete default host and definition composition.

## Changed executable coverage

**68/68 unique added executable production lines (100%)**, against the baseline:

| File | Covered / executable |
| --- | --- |
| `AskBuiltinPlan.swift` | 22 / 22 |
| `AskBuiltinToolHost.swift` | 39 / 39 |
| Added lines in `AskLocalEngine.swift` | 7 / 7 |

There are no uncovered added executable lines. This is changed physical-line
coverage, not whole-project or branch coverage. Protocol declarations, comments,
blank lines and synthesized memberwise accessors without LCOV `DA` entries are
outside the denominator. Deleted engine implementations are not counted again.

The committed `changed_swift_coverage.py` intersects added lines with LCOV `DA`
entries, deduplicates each file/physical line with the maximum hit count across
the two passes and emits `changed-coverage.json`. Both raw LCOV artifacts retain
only the changed production files; production line maps match across passes.
Reproduce with `python3 docs/validation/gul-454/changed_swift_coverage.py`.

The first artifact was exported using:

```sh
set -o pipefail
xcrun llvm-cov export .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests --instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata --format=lcov --ignore-filename-regex='\.build|Tests' | gzip > docs/validation/gul-454/swift-first.lcov.gz
```

Its three changed-file `SF` through `end_of_record` records were retained
unchanged; other records were removed to keep this evidence focused. The second
artifact directly selects the same three files:

```sh
set -o pipefail
xcrun llvm-cov export .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests Sources/Typeflux/Ask/Local/AskBuiltinPlan.swift Sources/Typeflux/Ask/Local/AskBuiltinToolHost.swift Sources/Typeflux/Ask/Local/AskLocalEngine.swift --instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata --format=lcov | gzip > docs/validation/gul-454/swift-default.lcov.gz
```

## Lint and self-review

`/usr/bin/time -p swiftlint lint --strict --quiet Sources/Typeflux/Ask/Local/AskBuiltinToolHost.swift Sources/Typeflux/Ask/Local/AskBuiltinPlan.swift Tests/TypefluxTests/AskBuiltinToolHostTests.swift Tests/TypefluxTests/AskBuiltinToolHostTests+Default.swift`
passes with no findings (0.24 s). Initial new-file lint findings were corrected
before test compilation: split the tests, use descriptive identifiers, wrap long
strings and document the unchanged fixed-schema `try!` plus the single cohesive
suspension-test length exception. Raw initial and final lint output is included.

Strict lint of the modified engine still exits 2 for existing findings. Compared
with the exact baseline file using the same config, no rule count increases:
line-length findings 64 -> 59, force-try 1 -> 0, statement-position 2 -> 1;
other counts are unchanged. Commands and raw JSON/time output are included:

- `git show HEAD:Sources/Typeflux/Ask/Local/AskLocalEngine.swift > docs/validation/gul-454/baseline/AskLocalEngine.swift` (before committing).
- `/usr/bin/time -p swiftlint lint --strict --quiet --reporter json --config .swiftlint.yml docs/validation/gul-454/baseline/AskLocalEngine.swift` (exit 2, 0.36 s).
- `/usr/bin/time -p swiftlint lint --strict --quiet --reporter json Sources/Typeflux/Ask/Local/AskLocalEngine.swift` (exit 2, 0.12 s).
- An additional lint attempt using `.swiftlint-baseline.json` also reports existing
  findings; retained as `swiftlint-engine.log.gz`.
- `git diff --check` passes.

Reviewed the complete dispatch sequence against baseline: binding validation,
pending/device-name classification, approval, reservation, save, await, reload,
binding validation, settlement/refresh, late-result rejection, delta, receipt
and advance retain their exact positions. The wrapper enforces the unchanged
limit before calling the injected port. Counters, usage, plan application and
device execution remain in engine orchestration.

The port contains Sendable value snapshots/results only. It carries no engine,
record, store, credentials/approval container or mutable state reference. The
host never imports or references the engine. Error strings, schema bytes,
definition order and dynamic history activation location are preserved. Default
composition is created once, and execution cannot construct a fallback host.

Reviewed session ownership and failure paths: unbudgeted calls reuse the existing
session; budgeted calls copy exactly its configuration, use the existing
`AskModelRedirectPolicy`, and defer `finishTasksAndInvalidate` on both successful
and failed web operations. Tests execute these cleanup lines and verify the
source transport remains usable; they do not observe private URLSession
internals or claim a live TLS/redirect integration. Arbitrary `web_fetch` still
fails closed. There are no new production tasks or resource ownership paths.
Test gates handle release-before-suspend, and every held task is released and
awaited on both success and throwing paths. Temporary storage is removed.

During self-review the late-result test was corrected to account for the
existing budget settlement refresh rather than require a byte-identical stale
budget summary. No production orchestration change was necessary. No new
secrets, permissions or provider/network policy changes were introduced.

This is C2 only. Remaining model/state ports, broader orchestration, pinned
dispatch, peer negotiation and alternate end-to-end execution remain in the
separate stage-3 backlog sibling; Stage 4 acceptance remains with architecture.
