## Scope and source identity

Measured during the production-integration run on 2026-10-03, macOS 26.6.2
(25G83), arm64, Apple Swift 6.4.0. These are fresh results; the earlier core
PR #266 report is retained in that PR's immutable history and is not counted
as validation for this follow-up.

Integration started on P06's released fixed adapter head
`2ece25153b3ce3d4beccff6ea3ad89ca25ddb703`, after its implementation run
finished. P06 subsequently merged as `bfc927cdfb1fdfd91acfa4a17710acdf741a4c75`.
The follow-up was moved to main `658e291ab5c6e62eed29abb3fae1595bb835afee`
without duplicate prerequisite commits. The released P06 tree and its squash
merge are identical; main's additional #267 changes only design documents.
Production/test/package/script trees before and after moving the follow-up
were explicitly compared and identical. The isolated baseline is that main
commit. Baseline and integration full UI suites ran sequentially on this host.

Both raw and approved browser/computer calls now use the new executors.
Production writes and authorization reuse remain off. Implementation delivery
is separate from the native acceptance and rollout gates below.

## Fresh results

| Check | Integration | Unmodified main baseline |
| --- | --- | --- |
| Focused automation, policy, approval, typed-result regression | 19 XCTest + 55 Swift Testing pass; no skips | Not substituted for integration results |
| Full `make coverage`: XCTest | 2,668 tests; 4 skips; zero failures | 2,668 tests; same 4 skips; zero failures |
| Full `make coverage`: Swift Testing | 695 tests; one failing test, four assertions | 686 tests; same failing test and four assertions |
| Production line coverage | 66,896 / 127,195 = **52.59%** | 66,947 / 127,401 = **52.55%** |
| New production routing/screenshot files: strict SwiftLint | Pass | Not applicable |
| Five new/refined executor/routing files: strict SwiftLint | Pass | Not applicable |
| Three existing shared files: strict SwiftLint | 55 violations, still fails | 90 violations |
| Diff whitespace check | Pass | Not applicable |

The full suite is **not green**. The only failing test in both full runs is
`AskAccountFooterClickTests.accountNameClickTogglesTheAccountCard`, at lines
37, 39, 43 and 44: popup showing/visibility/pointer assertions. It is outside
the changed code. No assertions were removed or relaxed to hide the failure.
P06's merged fixture migration eliminated the five obsolete engine-fixture
failures reported by the earlier P09 core run.

The four full-suite skips are the existing opt-in memory-settings screenshot
and three interactive native automation cases. Explicit native acceptance was
run separately, below. Full Swift Testing counts name test functions; their
parameterized target/scope/permission cases also ran.

The shared-file lint count covers `AskLocalTools.swift`,
`AskLocalTools+Approval.swift` and `AskTypedContent.swift`, not the whole repo.
The five-file strict pass covers `AskLocalTools+Automation.swift`,
`AskScreenObservation.swift`, `AskObservationStore.swift`,
`AskBrowserExecutor.swift` and `AskComputerExecutor.swift`. Whole-repo lint
success is not claimed.

`make coverage` exited at the inherited suite failure. Coverage was therefore
exported manually from each full run's two fresh `.profraw` files and its
actual `TypefluxTests.xctest` binary. Files older than the full-run start were
excluded. Exports were saved before further targeted/native runs; their
profiles were not mixed. The final cosmetic optional-initializer cleanup was
compiled and checked by the final targeted run; it changes no behavior.

## Coverage denominator

These are executable **Swift line** counts from LLVM, not branch coverage,
JavaScript coverage, native permission acceptance or business-effect evidence.

| Modified/new production file in this follow-up | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| AskLocalTools+Automation.swift | 70 / 70 | 100% |
| AskScreenObservation.swift | 33 / 33 | 100% |
| AskLocalTools.swift | 220 / 223 | 98.65% |
| AskLocalTools+Approval.swift | 105 / 114 | 92.11% |
| AskBrowserExecutor.swift | 193 / 195 | 98.97% |
| AskComputerExecutor.swift | 273 / 279 | 97.85% |
| AskObservationStore.swift (including receipt projection) | 95 / 99 | 95.96% |
| AskTypedContent.swift | 173 / 183 | 94.54% |
| **Eight complete files** | **1,162 / 1,196** | **97.16%** |

Added/modified executable lines intersected with LLVM LCOV `DA` records:
**131 / 133 = 98.50%**. This narrower changed-line measure has a different
line denominator from LLVM whole-file summaries; it is not used to replace
whole-file coverage. The two uncovered added lines are conservative receipt
encoding fallback and a native display-selector closure boundary.

The unchanged core files in this follow-up also ran: BrowserScripts 11/11,
ComputerTargetProbe 116/121, AutomationScriptRunner 29/29. The existing
AskDesktopActions helper remains **116/145 (80%)**, below the task's 90%
whole-file goal, with real AX traversal unavailable. Across all twelve P09
production files (including that helper), coverage is 1,434/1,502 = 95.47%.
Embedded JavaScript counts as Swift string construction lines; the real
WebKit DOM suite separately tests its behavior.

Full production coverage includes only `Sources/Typeflux/`, excluding tests,
fixtures, dependencies, generated/build outputs and CLI/audio C targets. Its
percentage did not decrease. Removing the legacy event/JS implementation
reduces the denominator; UI timing can also affect aggregate coverage, so the
percentage change is not attributed solely to additional tests.

## What the integration tests establish

- Raw and approved calls share the same executor; writes fail closed by
  default. Schemas advertise observation IDs and string refs. Numeric refs
  cannot bypass validation by supplying a selector; scroll requires x/y.
- Observations are scoped to trusted owner/conversation/tool, invalidated on
  rebind, single-use, and never restored as authority from cached results.
  Model-supplied owner/browser fields cannot redirect a write. An observed
  Safari cannot fall back to Chrome after the running-app selection changes.
- Target changes and late revocation fail before input dispatch. Cancellation
  after mouse-down returns an unknown outcome and deterministically posts
  mouse-up at the last delivered position. Unknown effects are not replayed.
- Missing elements retain `invalid` and `event_dispatched=false`; outcome and
  trusted observation survive the journal/cache, and legacy text retains
  dispatch/effect distinctions without enabling typed wire negotiation.
- Without AX evidence, screenshot consent remains usable but clears old write
  observations and issues no new one. Capture permission failure, returned
  display mismatch, display change and late revocation are rejected.
- Existing folder-grant isolation, MCP adapter, pending-call comparison,
  journal/grant consumption and late authorization regressions still pass.

## Real environment acceptance

The explicit entrypoint was run on the freshly built instrumented binary:

```sh
TYPEFLUX_AUTOMATION_ACCEPTANCE=1 swift test --skip-build --filter AskAutomationAcceptanceTests
```

Four tests ran: native permission evidence passed; three allowed-path cases
failed their environmental prerequisites, rather than being silently skipped.

| Native path | Observed prerequisite | Actual acceptance result |
| --- | --- | --- |
| Safari | Automation preflight `-600` (application not running) | Fixture actions not executed |
| Chrome | Automation preflight `-1744` (consent required) | Fixture actions not executed |
| Desktop | `AXIsProcessTrusted() == false` | Real drag/cancel and window-move actions not executed |
| Screen capture | `CGPreflightScreenCaptureAccess() == false` | Real screenshot acceptance not executed |

The complete native allow/deny matrix, browser JavaScript-from-Apple-Events
permission regression, real tab/window/navigation changes, display changes,
and combined live-model/MCP acceptance remain outstanding. WebKit and injected
tests are not substitutes. No TCC reset, permission bypass, browser preference
change or production capability enablement was performed. Keep writes and
reusable grants disabled until the required human acceptance is complete.

## Reproduction

```sh
swift test --enable-code-coverage --filter 'Ask(AutomationIntegration|LocalTools|LocalApproval|AgentTools|BrowserExecutor|ComputerExecutor|ObservationStore|BrowserDOM|AutomationScriptRunner|ComputerTargetProbe|ScopedApproval|ToolPolicy|TypedContentIntegration)Tests'
make coverage
```

When suite failure prevents report generation, merge **only that run's fresh
profiles** with `xcrun llvm-profdata merge -sparse`, then export the matching
`.build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests`
with `xcrun llvm-cov export`. Do not combine profiles from targeted/full/native
runs or from different binaries. Other SwiftPM backends may use a different
binary path. The prior core report is available in merged PR #266's history.
