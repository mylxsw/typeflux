# GUL-525: complete quick note capture

This completes the original new-note and append flows and revises the launcher UI. Work started from `fc073395`, then rebased onto `a57c0e12` after main received additional icon updates. The delivered UI uses the shared notebook artwork and result icon renderer, including its 36 pt footprint and sculpted/light preferences. There are no new backend dependencies or database migrations.

## Interface

- The composer owns the text. New capture shows a destination card and character count instead of echoing the entire body. Capture sizes to its content rather than reserving the full launcher height.
- Append opens a dedicated, keyboard-accessible note filter without replacing the draft. Results distinguish identical titles by excerpt, modification time and UUID identity. Selection never writes; a separate Return commits the reviewed addition.
- The append view separates the existing tail from the exact addition. After saving, the receipt offers Open and Undo. The next capture defaults to New note.
- Conflicts retain the input and require explicit reload/review or a new destination. Empty/error picker states, busy state and actions remain within the visible viewport. Target filters save no recent searches.

## Validation

Swift 6.4 on arm64 macOS. All selected scopes have passing final outcomes after the corrections and integration passes below. No full-project test run was performed.

| Pass | Result | Total runner wall time |
| --- | --- | --- |
| Initial focused preparation | Swift stopped the build because a test's asynchronous wait condition was edited during compilation. No tests executed. | 222.74 s |
| Same 13-suite coverage scope after fixing inputs | 107 Swift Testing methods in 12 suites passed; 29/30 localization XCTest methods passed. The failure identified the prohibited Traditional Chinese term `關鍵字`, corrected to `關鍵詞`. | 103.43 s |
| Native capture suite and the two relevant localization methods | All eight native methods and both localization methods passed. Included final copy deduplication and updated visual fixtures. | 108.27 s |
| Integration after rebase onto latest icon changes | All 25 methods in native capture, icon resources and feature search suites passed. | 136.27 s |
| Final native pass after adopting the shared renderer in picker rows too | All eight native methods passed; final snapshots regenerated. | 70.25 s |

Times include preparation, build/discovery, startup and execution, not just test execution. The `make coverage` wrapper's subsequent HTML rendering is outside the runner timer. No cached passing results were substituted for execution.

Initial scope:

```sh
TYPEFLUX_CAPTURE_SNAPSHOTS=docs/validation/gul-525-complete make coverage SUITE="AskNoteCaptureTests AskNoteCaptureAppendTests AskNoteCaptureInteractionTests AskLauncherFeatureIconsTests AskKeywordMatcherTests AskKeywordAliasTests AskKeywordListPresentationTests AskKeywordDraftTests AskPluginSessionTests AskLauncherInputHistoryTests AskNotebookEntryRegressionTests AskNotebookStoreTests LocalizationResourceTests"
```

Scoped follow-ups:

```sh
TYPEFLUX_CAPTURE_SNAPSHOTS=docs/validation/gul-525-complete python3 scripts/test_groups.py --coverage --suite AskNoteCaptureInteractionTests --filter 'LocalizationResourceTests/(testLauncherPolishKeysAndChineseTerminologyAreComplete|testQuickNoteCaptureCopyExistsInEveryLanguage)'
TYPEFLUX_CAPTURE_SNAPSHOTS=docs/validation/gul-525-complete python3 scripts/test_groups.py --coverage --suite AskNoteCaptureInteractionTests --suite AskLauncherFeatureIconsTests --suite AskLauncherFeatureSearchTests
TYPEFLUX_CAPTURE_SNAPSHOTS=docs/validation/gul-525-complete python3 scripts/test_groups.py --coverage --suite AskNoteCaptureInteractionTests
```

Behavior-to-test mapping:

- `AskNoteCaptureAppendTests`: exact separators/whitespace, metadata and original AI text preservation, atomic replacement/revision, duplicate titles, deleted or changed targets, explicit reload, uncertain commits, retry deduplication, undo conflicts, trash, asynchronous search cancellation, failure messages, dismissal and account reset.
- `AskNoteCaptureInteractionTests`: native input, IME, picker arrows/Return/Escape, save admission, clear/open/undo/reload/retry buttons, empty search results, target selection without writing and native frame bounds in both appearances.
- Existing capture, keyword, session, history, notebook entry and SQLite suites protect unchanged new-note behavior and shared routing/persistence contracts. Icon resources and feature search cover the latest shared renderer and editable prefix spellings. Localization validates all five languages.

## Coverage and lint

Changed executable production lines against `a57c0e12`: **523 / 527, 99.24%**. This is line coverage of this change, not project-wide or branch coverage. `changed-coverage.txt` lists each file; `coverage.lcov.gz` stores normalized line counts. Unchanged source mappings come from the full focused scope, and the UI mapping comes from its final rebuilt native pass.

```sh
python3 docs/validation/gul-457/changed_coverage.py docs/validation/gul-525-complete/coverage.lcov.gz --base a57c0e12
```

The six capture production files pass strict SwiftLint; all nine capture Swift/test files pass SwiftFormat lint. Existing modified production files have 207 findings versus 207 at the updated base, with no increased file/rule/severity counts (`lint-comparison.json`). `git diff --check` passes. Existing repository lint debt and compiler warnings remain outside this change.

## Self-review

Reviewed the complete entry/search/select/review/commit/receipt/undo path, blank and invalid input, bounded queries, duplicate submission, cancellation, storage failure, uncertain commits, concurrent edits/deletion, privacy and localized copy. Append and its old-text revision use the existing transaction-backed compare-and-swap API. Retry reconciles an already committed addition and refuses ambiguous newer text. Undo retains newer metadata and refuses to replace a newer snapshot; a new-note undo is recoverable through Recently Deleted. Version comparisons include the entire stored snapshot rather than only a timestamp.

Account/generation checks prevent late completions from reviving old drafts. Search cancellation and query tokens prevent stale results from replacing a newer filter; late reload completion cannot steal another feature's focus. Saving locks admission and the editor; dismissing the launcher preserves an admitted operation. Neither draft nor target filter goes to AI, input history or diagnostic error text. Code and documentation describe both capture modes.

Visually checked native view-cache snapshots generated from synthetic notes. These are app-view renders, not captures of the user's desktop.

| State | Light | Dark |
| --- | --- | --- |
| New note | [View](capture-light.png) | [View](capture-dark.png) |
| Target selection | [View](picker-light.png) | [View](picker-dark.png) |
| Append preview | [View](append-light.png) | [View](append-dark.png) |
| Append receipt | [View](appended-light.png) | [View](appended-dark.png) |
| New-note receipt | [View](saved-light.png) | [View](saved-dark.png) |

Additional states: [conflict/review](conflict.png), [empty target search](picker-empty.png). Earlier UI snapshots remain in `../gul-525/` for comparison.
