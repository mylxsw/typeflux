# GUL-318 validation record

Executed on macOS with Apple Swift 6.4. The feature uses synthetic OCR and model
responses in tests; no external model request was made.

| Check | Result |
| --- | --- |
| `swift build` | Passed |
| `TYPEFLUX_ASK_SNAPSHOTS=../gul-318-snapshots swift test --enable-code-coverage --filter 'AskScreenshot\|ExclusiveUIStateLanguageTests'` | 76 tests in 8 suites passed; 16 snapshots rendered |
| `swift test --no-parallel --enable-code-coverage --filter LauncherSettingsPolishTests` | 10 tests passed after fixing the control press helper |
| SwiftLint for the screenshot text plugin, new organization extension and both new test files | Passed |
| `plutil -lint` for all five modified localizations | Passed |
| `git diff --check` | Passed |

## Coverage

Coverage was collected with:

```sh
swift test --build-system native --no-parallel --enable-code-coverage \
  --filter 'AskLauncherHeaderTests|AskLauncherMotionTests|AskScreenshotTextOrganizationTests'
```

All 10 organization tests passed; the two existing UI suites failed.
The resulting raw profiles were merged with `llvm-profdata` and read with
`llvm-cov report` against the instrumented test executable.

| Production file | Line coverage | Region coverage |
| --- | --- | --- |
| `AskScreenshotTextPlugin+Organization.swift` | 76/76 (100%) | 31/31 (100%) |
| `AskScreenshotTextPlugin.swift` | 75/81 (92.59%) | 37/44 (84.09%) |
| Combined | 151/157 (96.18%) | 68/75 (90.67%) |

## Full-suite blocker

`swift test --no-parallel --enable-code-coverage` completed its XCTest phase:
3,635 tests executed, including 17 skips, with zero failures. Swift Testing
reported failures in `AskLauncherHeaderTests` and `AskLauncherMotionTests`, then
stalled in the settings test's synchronous AppKit mouse tracking loop. Sampling
identified `NSControl.mouseDown`; only the owned test process was stopped.
The settings helper now uses the project's existing control press helper, and
its complete 10-test suite passes. Its behavioral assertions are unchanged.

The launcher UI failures were also reproduced after stashing **all** feature
changes and confirming a clean tree at base commit
`45c31bc3272cd287a841cee4fc0ec9d7e10e444b`:

```sh
swift test --build-system native --no-parallel --enable-code-coverage \
  --filter 'AskLauncherHeaderTests|AskLauncherMotionTests'
```

That clean-base run exited 1: 17 tests in 2 suites, 5 issues. Screenshot hover
tests could not find their child preview panel (`AskLauncherHeaderTests.swift`,
lines 233, 392 and 411). Clearing the editor left a 170-point height difference
in both appearances (`AskLauncherMotionTests.swift`, line 127). The full feature
changes were restored afterward. These test files and their production UI logic
are unchanged by this PR. A green full-suite result remains pending.

## Self-review

Checked explicit action routing, Markdown streaming and rendering, all exports,
SQLite note persistence, restoring original text, retry and authentication
actions, blank OCR/model responses, capture replacement and cancellation.
The capture ID and existing session generation checks prevent stale results.
Only this screenshot's text reaches the text-processing model; the prompt treats
source content as data and preserves its language and details. Existing LLM
stream cancellation is reused. Reviewed Chinese/English light/dark rendering and
five-language strings. Fixed the test helper hang described above.
