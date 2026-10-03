## Scope and environment

Measured on 2026-10-03, macOS 26.6.2 (25G83), arm64, Apple Swift 6.4.0.
The final source baseline is main `fe1d68e446d715ad9f20e3517d2c170191ec4af9`,
which contains the squash-merged P02 #261. The isolated baseline checkout and
P09 checkout used the same compiler and ran their UI suites sequentially.
No previous issue's test count is counted as a P09 result.

This is the independent executor delivery. Production routing and typed-result
integration remain pending the compatible P06 adapter; see
`p09-observation-executors.md`. No production writes or reusable permissions
are enabled.

## Results

- Targeted executor/identity/receipt/managed-process tests: 19 Swift Testing
  tests plus 4 XCTest real WebKit DOM tests passed, no skips. Parameterized
  target-change/cancellation tests also exercise multiple cases.
- Final `make coverage`: 2,652 XCTest tests, 4 skipped, 71 failure assertions
  (2 unexpected) in 5 existing `AskLocalEngineReentrancyTests` cases; all 684
  Swift Testing tests passed. This is **not** a green full suite. The skips are
  one pre-existing opt-in screenshot test and three new interactive acceptance
  cases. The five engine failures are reproduced in an isolated base checkout.
- Same-main baseline: 2,644 XCTest tests, 1 skipped, 76 failure assertions
  (2 unexpected) in the same five engine cases; 665 Swift Testing tests with
  one account-popup failure (4 assertions). Assertion totals in the delayed
  engine fixtures vary with timing; the failing test set is unchanged.
- Strict SwiftLint passes for all six new production files; `git diff --check`
  passes. The standalone desktop fixture compiles with `xcrun swiftc`.
- `make coverage` stops at the suite failure, so coverage was exported by
  merging that run's `.profraw` files with `llvm-profdata` and exporting the
  actual `TypefluxTests.xctest` binary with `llvm-cov`. No previous run's
  profiles were included.

## Coverage denominator

These are executable **Swift line** counts from LLVM, not JS branch coverage,
OS acceptance or business-effect evidence. The embedded JS string counts as
Swift construction lines; the WebKit tests separately execute its DOM behavior.
Injected target/event tests do not imply that native TCC-granted execution ran.

| Production file | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| AskObservationStore.swift (includes receipt projection) | 89 / 93 | 95.70% |
| AskBrowserExecutor.swift | 190 / 193 | 98.45% |
| AskBrowserScripts.swift | 11 / 11 | 100% |
| AskComputerExecutor.swift | 272 / 278 | 97.84% |
| AskComputerTargetProbe.swift | 116 / 121 | 95.87% |
| AskAutomationScriptRunner.swift | 29 / 29 | 100% |
| **Six new files** | **707 / 725** | **97.52%** |
| Existing AskDesktopActions.swift, whole file | 116 / 145 | 80.00% |
| **All seven new/modified production files** | **823 / 870** | **94.60%** |

The existing desktop helper remains below the 90% whole-file target; real AX
tree traversal with permission granted was unavailable. Its optional element
identity callback is the only production behavior addition to an existing file.
Full production coverage counts only `Sources/Typeflux/`, excluding tests,
fixtures, dependencies, generated/build outputs and the CLI/audio C targets.
P09 covers 66,464 / 126,878 lines (52.38%), compared with the isolated same-main
baseline's 65,723 / 126,149 lines (52.10%). Aggregate coverage did not decrease.
The difference also includes run-to-run UI test variation; it is not claimed
as an improvement solely caused by these new modules.

## Real environment acceptance

The explicit command was run, not merely listed:

```sh
TYPEFLUX_AUTOMATION_ACCEPTANCE=1 swift test --filter AskAutomationAcceptanceTests
```

It ran four tests: permission evidence passed; three allowed-path cases failed
their environmental prerequisites, rather than silently skipping:

| Native path | Observed prerequisite | Execution result |
| --- | --- | --- |
| Safari | Automation preflight `-600` (application not running) | Fixture actions not executed |
| Chrome | Automation preflight `-1744` (consent required) | Fixture actions not executed |
| Desktop | `AXIsProcessTrusted() == false` | Real drag/cancel and window-move actions not executed |
| Screen capture | `CGPreflightScreenCaptureAccess() == false` | Real screenshot acceptance not executed |

The native AX denial path is exercised and fails closed. A complete macOS
allow/deny matrix, browser JavaScript-from-Apple-Events permission regression,
real tab/window/navigation changes and real display changes remain outstanding.
No TCC reset, browser preference change or permission bypass was performed.

Real WebKit DOM tests passed for native input/textarea/contenteditable setters,
input/change event delivery, framework-style setter overrides, value rejection,
missing/read-only/unsupported elements, malformed selectors, one-shot versioned
refs, DOM replacement, URL/viewport/scroll changes and focus/visibility events.
This is not a substitute for Safari/Chrome AppleScript acceptance.

## Known full-suite failures

The following tests still use general web-fetch fixtures that P08 disabled on
main. The P06 adapter includes a fixture migration, but that unmerged work is
not duplicated here. Every existing assertion is preserved:

- `testDeletedConversationIsNotReturnedOrRecreatedByLateFetch`
- `testLateFetchCannotOverwriteANewRunAfterPurgeAndCancel`
- `testPurgeAndCancelRejectLateFetchAndKeepCommittedPlan`
- `testPurgeAndSteeringKeepBothPlanDeltasAndDeviceReceipts`
- `testPurgeDuringFetchNeverRestoresMemoryOnReadOrReopen`

The earlier `a9ebc93d...` comparison in this same run also reproduced these five
cases (77 assertions) and the unrelated account-popup Swift Testing failure.
It is not used as the final main coverage denominator.

## Reproduction

```sh
swift test --filter 'Ask(BrowserDOM|BrowserExecutor|ComputerExecutor|ComputerTargetProbe|ObservationStore|AutomationScriptRunner)Tests' --enable-code-coverage
make coverage
xcrun llvm-profdata merge -sparse .build/out/Products/Debug/codecov/*.profraw -o p09.profdata
xcrun llvm-cov export .build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests -instr-profile=p09.profdata > p09-coverage.json
```

Paths above match this SwiftPM/Xcode build backend. Other toolchains may use
`TypefluxPackageTests.xctest`; use their actual binary and profiles. Do not mix
profiles between the targeted run, the full run, and explicit native acceptance.
