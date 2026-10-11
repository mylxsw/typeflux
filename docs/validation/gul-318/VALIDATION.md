# GUL-318 validation record

Executed on macOS with Apple Swift 6.4. The feature uses synthetic OCR and model
responses in tests; no external model request was made.

| Check | Result |
| --- | --- |
| `swift build` | Passed |
| `swift test --no-parallel --enable-code-coverage` | XCTest: 3,635 tests, 17 skips, zero failures. Swift Testing stalled in the existing real ScreenCaptureKit integration test; no assertion failures preceded it |
| All Swift Testing suites, split across six fresh processes | 2,292 tests in 342 suites passed; only `ScreenCaptureServiceTests/capturesTheRealScreen` excluded |
| `TYPEFLUX_ASK_SNAPSHOTS=../gul-318-snapshots swift test --enable-code-coverage --filter 'AskScreenshot\|ExclusiveUIStateLanguageTests'` | 76 tests in 8 suites passed; 16 snapshots rendered |
| `swift test --no-parallel --enable-code-coverage --filter LauncherSettingsPolishTests` | 10 tests passed after fixing the control press helper |
| `swift test --no-parallel --enable-code-coverage --filter 'AskLauncherHeaderTests\|AskLauncherMotionTests'` | 17 tests in 2 suites passed after stabilizing their UI fixtures |
| `swift test --disable-xctest --no-parallel --enable-code-coverage --filter ScreenCaptureServiceTests --skip 'TypefluxTests.ScreenCaptureServiceTests/capturesTheRealScreen'` | 8 fixture tests passed after synchronizing capture records |
| Double-display fixture test with `--maximum-repetitions 50 --repeat-until fail` | All 50 repetitions passed |
| SwiftLint for the screenshot text plugin, new organization extension and both new test files | Passed |
| `plutil -lint` for all five modified localizations | Passed |
| `git diff --check` | Passed |

## Coverage

The Swift Testing batches partitioned every suite from
`swift test --enable-code-coverage list --skip-build --disable-xctest`. Each ran
with the following options and a disjoint suite filter:

```sh
swift test --skip-build --disable-xctest --no-parallel --enable-code-coverage \
  --filter '<suite partition>' \
  --skip 'TypefluxTests.ScreenCaptureServiceTests/capturesTheRealScreen'
```

All six commands exited 0 with complete Swift Testing summaries: 383, 381, 382,
382, 382 and 382 tests respectively. Their filters covered all 342 suites and
all 2,293 listed test methods except the one explicitly excluded real-system
test. Raw profiles from the successful batches and completed XCTest phase were
merged with `llvm-profdata`. `llvm-cov report` read the merged profile against
`.build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests`,
restricted to the two screenshot text production files below.

| Production file | Line coverage | Region coverage |
| --- | --- | --- |
| `AskScreenshotTextPlugin+Organization.swift` | 76/76 (100%) | 31/31 (100%) |
| `AskScreenshotTextPlugin.swift` | 81/81 (100%) | 44/44 (100%) |
| Combined | 157/157 (100%) | 75/75 (100%) |

## UI test fixture repairs

An initial `swift test --no-parallel --enable-code-coverage` run completed its XCTest phase:
3,635 tests executed, including 17 skips, with zero failures. Swift Testing
reported failures in `AskLauncherHeaderTests` and `AskLauncherMotionTests`, then
stalled in the settings test's synchronous AppKit mouse tracking loop. Sampling
identified `NSControl.mouseDown`; only the owned test process was stopped.
The settings helper now uses the project's existing control press helper, and
its complete 10-test suite passes. Its behavioral assertions are unchanged.

The initial launcher UI failures were reproduced after stashing **all** feature
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
changes were restored afterward.

Diagnostics confirmed that the editor had been cleared, but the initial height
was recorded before captured context finished laying out. The typing test now
prepares its fixed context before opening the launcher, flushes layout and waits
for resizing to settle before recording its baseline. Hover tests now wait for
the actual child preview panel and flush pending layout, replacing a fixed
300 ms sleep. Their original size, focus, click and content assertions remain.
All 17 tests in these two suites now pass; their production UI logic is unchanged.

A later validation batch exposed a race in the fake screen capturer: the
production service captures displays in parallel, but its test recorder appended
to one array without synchronization. The recorder's reads and writes now use
`NSLock`. Its eight fixture tests pass with the original assertions, including
50 consecutive repetitions of the double-display case.

## Real screen capture limitation

The final full-suite run reached the existing `capturesTheRealScreen()` test,
which calls the system ScreenCaptureKit service when the permission preflight
returns true. Its request did not return. Sampling showed continuing system
screen-capture callbacks and main-thread SwiftUI layout; only the owned test
process was stopped after checking its PID against the Multica daemon.
The remaining validation excludes this one real-system integration test. Its
test and production capture implementation are unchanged. Screenshot capture,
geometry, permissions and follow-up behavior are still exercised with fixtures;
real screen capture and external-model quality require manual verification.

## Self-review

Checked explicit action routing, Markdown streaming and rendering, all exports,
SQLite note persistence, restoring original text, retry and authentication
actions, blank OCR/model responses, capture replacement and cancellation.
The capture ID and existing session generation checks prevent stale results.
Only this screenshot's text reaches the text-processing model; the prompt treats
source content as data and asks it to preserve the language and details. Existing LLM
stream cancellation is reused. Reviewed Chinese/English light/dark rendering and
five-language strings. Fixed the control tracking hang, the two UI fixture
timing problems, and the fake capturer's recording race described above. Removed
temporary diagnostics before validation.
