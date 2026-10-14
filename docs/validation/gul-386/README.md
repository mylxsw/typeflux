## Launcher primary action

The primary button, Return, tooltip, accessibility label and footer resolve the same
action: open chat, send to AI, or confirm the selected search/home/plugin action.
Command-Return remains the explicit AI entry. Command-O and the separate window
button share capability checks and preserve an existing result or submitted stream.
Empty keywords, approvals, lists and images do not offer a generic text result window.

Native SwiftUI/AppKit snapshots use stubbed search and translation data:

| State | Screenshot |
| --- | --- |
| Selected application, light | [execute-light.png](execute-light.png) |
| Selected application, dark | [execute-dark.png](execute-dark.png) |
| Translation result and independent window control | [keyword-dark.png](keyword-dark.png) |
| Empty input without a selected home action | [chat-light.png](chat-light.png) |
| AI question without a selected result | [send-dark.png](send-dark.png) |

## Validation

`swift build` passed (83.42 seconds). After merging `main` at `5c79e4e0`, focused
instrumented validation passed 165 distinct test methods, including parameterized cases:

| Suite | Methods | Change coverage |
| --- | ---: | --- |
| AskLauncherPrimaryActionTests | 17 | Intent/readiness, mouse/Return parity, stale targets, history, windows, duplicate activation and native renders |
| AskLauncherHeaderTests | 20 | Shared composer rendering, attachments, recording and keyboard callbacks |
| AskLauncherNumberShortcutTests | 5 | Command badges, including absence of an AI badge on execution actions |
| AskQuickResultsInteractionTests | 93 | Existing search, calculator, plugin, workflow and window callers |
| AskPluginSessionTests | 9 | Keyword session transitions and result lifetimes |
| AskLauncherInputHistoryInteractionTests | 6 | Native history shortcuts and input composition |
| AskCalendarPluginTests | 5 | Calendar registration and key mapping |
| AskWorkflowKeywordSelectionTests | 10 | Upstream optional/no-input workflows, selection, Tab entry and explicit Return execution |

The final instrumented run selected all 165 methods in these eight suites. All passed.
Total command wall time was **632.23 seconds**: 257.24 seconds for preparation/discovery
and 374.97 seconds for execution/runner overhead.

Coverage of added executable Swift lines relative to the merged `main` was **266/292 (91.10%)**.
The complete new resolver/debounce file, `AskLauncherPrimaryAction.swift`, had **96.00%**
line coverage. These are focused change metrics, not whole-project coverage.

The repository's normal `make coverage SUITE=... FILTER=...` runner was used first.
On Swift 6.4, its `swift test --enable-code-coverage list` discovery build did not
instrument the binary; the following `--skip-build` test run therefore had no profile.
The successful run used a validation-local Swift wrapper to explicitly execute
`swift build --build-system native --skip-update --build-tests --enable-code-coverage --jobs 4`
before `swift test --build-system native --skip-update list --skip-build`, then kept the
runner's explicit test filter. Object coverage mappings and the generated profile were
verified before reading LLVM line counters. Repository build scripts were unchanged.

Earlier validation attempts and fixes:

| Total wall time | Result and resolution |
| ---: | --- |
| 71.17 s | Test compilation rejected a missing calculator argument and mutating calls inside expectation macros; fixed the new tests. |
| 215.74 s | Fixed the new accessibility traversal helper's lazy-iteration crash and the execution-mode badge expectation. |
| 401.03 s | 126 methods ran; one existing plugin test still expected the header to send AI. Updated it to expect plugin confirmation while retaining Command-Return AI checks. |
| 68.99 s | The updated plugin expectation passed; fixed an optional initial height report in the screenshot fixture. |
| 467.49 s | 43 methods passed on the native engine, but coverage was still absent. Explicit instrumentation before discovery resolved the toolchain issue. |
| 349.58 s | Pre-merge instrumented 46-method scope passed and emitted coverage successfully. |
| 632.23 s | After merging main, all 165 relevant methods passed, including the newly added optional/no-input workflow behavior. |

`git diff --check` passed. SwiftLint on touched files still reports six existing
complexity/type-size errors (seven in the HEAD baseline); comparison by file and rule
found no added findings. New production and test files have no lint findings.

Self-review checked action routing, stale/empty/error states, duplicate submissions,
input-method ownership, result handoff lifetimes, account/draft isolation, sensitive
data handling, accessibility and documentation consistency. It tightened history
Return readiness and both Command-O paths, and excluded approvals and unsupported
rich results from generic text-window handoff.
Merge review also kept the upstream workflow selection behavior: a no-input workflow
entered with Tab can still be explicitly run through the primary action. Translation
keys are grouped beside the existing chat keys to avoid competing file-end additions.
