# GUL-525: launcher quick notes

Phase one adds `n` / `记` for manual, local note creation. Appending remains a later phase. No backend or schema migration is required.

## Validation

Swift 6.4, arm64 macOS. Tests use isolated fixtures, SQLite stores and synthetic launcher windows. No live model or user notes were used.

| Scope / command | Result | Runner total wall time |
| --- | --- | --- |
| `make coverage SUITE="AskNoteCaptureTests AskNoteCaptureInteractionTests AskKeywordMatcherTests AskKeywordAliasTests AskKeywordListPresentationTests AskKeywordDraftTests AskPluginSessionTests AskLauncherInputHistoryTests AskNotebookEntryRegressionTests KeywordHotkeyRunnerTests"` | First preparation failed compiling two test macro calls; fixed by evaluating mutating state calls before `#require`. No tests executed. | 423.95 s, including fresh dependencies/build |
| Same scope after the compilation fix | 78 tests executed. Four methods reported six issues: stale keyword list/count expectations and the newline event fixture. Remaining methods passed. | 119.10 s |
| `make coverage SUITE="AskNoteCaptureInteractionTests AskKeywordAliasTests AskKeywordListPresentationTests"` | All 20 tests passed after updating expectations, supplying the real Return character, and fixing the capture viewport. This also checks action visibility/clicks in a 420 pt launcher. | 129.66 s |
| `python3 scripts/test_groups.py --coverage --suite LocalizationResourceTests` | 29 tests executed; the key parity method failed for three languages. Confirmed that HEAD already lacked two screenshot error keys in each of zh-Hant, ja and ko; supplied translations. Other 28 methods passed. | 84.69 s |
| Capture suite plus the two localization checks (command below) | All 10 capture tests and two localization tests passed. Includes the final help-entry draft restoration fix and the new per-language capture-copy check. | 92.67 s |

Times are the runner's end-to-end measurements, including preparation, build/discovery, startup and execution. The `make coverage` wrapper's subsequent HTML/LCOV rendering is outside that timer. No full-suite run was requested or performed. All selected tests have a passing final outcome after the scoped retries above.

```sh
python3 scripts/test_groups.py --coverage --suite AskNoteCaptureTests --filter 'LocalizationResourceTests/(testEveryClientLanguageContainsTheSameKeysAsEnglish|testQuickNoteCaptureCopyExistsInEveryLanguage)'
```

Change-to-test mapping:

- Capture state, storage and lifecycle: `AskNoteCaptureTests`; original Markdown whitespace, blank input, title fallback, explicit writes, duplicate admission, failed/uncertain commits, UUID reconciliation, concurrent edits/deletion, account reset, reopening during a save and process-local draft recovery.
- Native launcher behavior: `AskNoteCaptureInteractionTests`; Return, Shift-Return, marked text, bare prefix restoration, blocked AI shortcut, continuous capture, Escape, clear/open actions and both appearances. Snapshots use `TYPEFLUX_CAPTURE_SNAPSHOTS=docs/validation/gul-525`.
- Shared routing and persistence: keyword matcher/alias/list/draft suites, plugin session, launcher input history, notebook entry regressions and keyword hotkey runner. These protect the existing `nb` / `notebook` entry points and custom keyword migration.
- Resource changes: localization parity and the dedicated capture-copy check across all five languages.

## Coverage and lint

Changed executable production lines: **300 / 318, 94.34%**. This is changed-line coverage, not project-wide coverage. `changed-coverage.txt` lists each file. `coverage.lcov.gz` retains normalized source/line counts combined from the focused runs; unchanged-source results are retained, and changed helper/view mappings come from their rebuilt runs.

To reproduce the intersection before another source edit:

```sh
python3 docs/validation/gul-457/changed_coverage.py docs/validation/gul-525/coverage.lcov.gz --base HEAD^
```

The four new production files pass strict SwiftLint. All six new Swift files pass SwiftFormat lint. Existing modified production files have 242 lint findings versus 243 at the base, with no increased file/rule/severity counts (`lint-comparison.json`); the repository still has pre-existing lint debt. `git diff --check` passes.

## Self-review

Reviewed entry-to-write-to-receipt/open behavior, empty and invalid input, failures, duplicate submissions, asynchronous completion ownership, concurrent edits/deletion, privacy, localization and compatibility. Fixed draft loss on restoration, prevented retries from replacing already committed notes, retained common dismissal cleanup, kept bare-prefix entry from submitting, preserved drafts when reentering through help, and constrained the preview to the actual visible viewport. Capture content stays out of submitted and abandoned launcher input history; fixed error messages do not expose store diagnostics. Admitted saves retain their store and completion handle without keeping the model alive or overwriting another account/presentation's unrelated input.

Visually inspected the native view-cache snapshots below. They show synthetic content; they are not desktop captures of the user's apps.

| Preview | Receipt |
| --- | --- |
| [Light](capture-light.png) | [Light](saved-light.png) |
| [Dark](capture-dark.png) | [Dark](saved-dark.png) |
