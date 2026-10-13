Vocabulary uses the shared native sortable table, source segments and sheet. History uses date sections with navigation rows, solid grouped detail sections and the existing audio, retry and transfer paths. Filtered history scans storage pages off the main thread and retains its raw cursor; deletion and clear reject stale query results.

## Screenshots

Native WindowServer captures from an earlier run of `VocabularyHistorySnapshotTests`, with isolated settings and synthetic data. Content stays solid in both styles. These 36 reference captures precede the native history Back toolbar rework and the expanded pipeline timestamp fixture; the acceptance owner must regenerate them from the PR head.

| Surface | Classic light | Classic dark | Liquid Glass light | Liquid Glass dark |
| --- | --- | --- | --- | --- |
| Vocabulary | [PNG](snapshots/vocabulary-classic-light.png) | [PNG](snapshots/vocabulary-classic-dark.png) | [PNG](snapshots/vocabulary-liquidGlass-light.png) | [PNG](snapshots/vocabulary-liquidGlass-dark.png) |
| Search with no results | [PNG](snapshots/vocabulary-search-empty-classic-light.png) | [PNG](snapshots/vocabulary-search-empty-classic-dark.png) | [PNG](snapshots/vocabulary-search-empty-liquidGlass-light.png) | [PNG](snapshots/vocabulary-search-empty-liquidGlass-dark.png) |
| Empty vocabulary | [PNG](snapshots/vocabulary-empty-classic-light.png) | [PNG](snapshots/vocabulary-empty-classic-dark.png) | [PNG](snapshots/vocabulary-empty-liquidGlass-light.png) | [PNG](snapshots/vocabulary-empty-liquidGlass-dark.png) |
| Add sheet | [PNG](snapshots/vocabulary-sheet-classic-light.png) | [PNG](snapshots/vocabulary-sheet-classic-dark.png) | [PNG](snapshots/vocabulary-sheet-liquidGlass-light.png) | [PNG](snapshots/vocabulary-sheet-liquidGlass-dark.png) |
| History | [PNG](snapshots/history-classic-light.png) | [PNG](snapshots/history-classic-dark.png) | [PNG](snapshots/history-liquidGlass-light.png) | [PNG](snapshots/history-liquidGlass-dark.png) |
| Record details | [PNG](snapshots/history-detail-classic-light.png) | [PNG](snapshots/history-detail-classic-dark.png) | [PNG](snapshots/history-detail-liquidGlass-light.png) | [PNG](snapshots/history-detail-liquidGlass-dark.png) |
| Pipeline details | [PNG](snapshots/history-pipeline-classic-light.png) | [PNG](snapshots/history-pipeline-classic-dark.png) | [PNG](snapshots/history-pipeline-liquidGlass-light.png) | [PNG](snapshots/history-pipeline-liquidGlass-dark.png) |
| History with no matches | [PNG](snapshots/history-filter-empty-classic-light.png) | [PNG](snapshots/history-filter-empty-classic-dark.png) | [PNG](snapshots/history-filter-empty-liquidGlass-light.png) | [PNG](snapshots/history-filter-empty-liquidGlass-dark.png) |

Liquid Glass accessibility fallbacks: [Reduce Transparency light](snapshots/reduce-transparency-liquidGlass-light.png), [dark](snapshots/reduce-transparency-liquidGlass-dark.png), [Increase Contrast light](snapshots/contrast-liquidGlass-light.png), [dark](snapshots/contrast-liquidGlass-dark.png).

## Acceptance commands

The latest issue instruction centralizes all Mac builds, tests and screenshots with the acceptance owner. The final implementation is awaiting that validation. Run on a Mac with a WindowServer session and Screen Recording permission for the snapshot host:

```bash
swift build
swift test --no-parallel --enable-code-coverage --filter 'SettingsWindowLifecycleTests|TypefluxNavigationTestSupportTests|DockVisibilityControllerTests|TypefluxNavigationInteractionTests|TypefluxPresentationInteractionTests|HistorySettingsBackButtonTests|VocabularyHistorySettingsTests|HistorySettingsQueryTests|VocabularyFilterTests|TypefluxTableDeleteKeyTests|TypefluxWindowTitleLifecycleTests|TypefluxUIControlsTableTests|VocabularyStoreTests|VocabularyStoreExtendedTests|SettingsViewModelHistoryAudioTests|HistoryProcessingDiagnosticsTests|HistoryRetryPlanTests|HistoryExportDestinationTests|FileHistoryStoreTests|SQLiteHistoryStoreTests|SettingsWindowNavigationTests|SettingsSearchScopeTests|SettingsOrganizationTests|StudioHistoryRowLayoutTests|VoiceInputNavigationTests'
TYPEFLUX_VOCABULARY_HISTORY_SNAPSHOTS="$PWD/artifacts/gul349-snapshots" swift test --no-parallel --enable-code-coverage --filter VocabularyHistorySnapshotTests
```

The snapshot command captures Vocabulary, unmatched search, empty library, add sheet, History date groups, record details, pipeline stages and unmatched audio filter in Classic/Liquid Glass × light/dark. It also captures Liquid Glass with Reduce Transparency and Increase Contrast in both appearances. Check the history Back button after opening a record, including a narrow window's native toolbar overflow. The tests use synthetic data and isolated defaults/storage, and restore the localization and vocabulary fixture.

For the window-lifecycle rework, start with the focused command below. Require both the two-window test result and the Swift Testing summary; a zero exit code alone did not establish completion in acceptance round 3.

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter 'SettingsWindowLifecycleTests|TypefluxNavigationTestSupportTests|HistorySettingsBackButtonTests|VocabularyHistorySettingsTests' 2>&1 | tee artifacts/gul349-window-lifecycle.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" (passed|failed)' artifacts/gul349-window-lifecycle.log &&
rg -q 'Test run with ' artifacts/gul349-window-lifecycle.log
```

## Return-navigation rework

The acceptance owner's second pass built latest main + PR #455 and passed 131 XCTest tests and the original return-navigation test, but the new Back test still reported an enabled button on the list and a rejected accessibility press. The main-actor factory correction from `1323d73` is retained.

Back now hosts its real `NSButton` inside a generic native view in a dedicated navigation `ToolbarItem`. The contents receive `.disabled` when no selected record is being presented; each representable update applies that environment to the child button and restores its coordinator, target and action. The target is bound to the presenting window's selection and cleared on teardown. Tests resolve the hosted control again after toolbar updates, check its identifier/target/selector, and retain the disabled-state and accepted-accessibility-press assertions. They also cover native clicks, record deletion, section scope and two-window isolation. The original failing assertion and press helper are unchanged.

Acceptance round 3 confirmed the Back effect checks pass, but the Swift Testing process exited before producing a result for the two-window test. The changes from `8233a3f6` and `65f27653` are retained: both localization additions survive, and toolbar AX presses are checked by their navigation effect rather than AppKit's Boolean return value.

The settings controller's close handler, `StudioShell`, and `TypefluxWindow` contain no application-quit call. The two-window test previously nested two helpers that each managed process-wide activation/accessibility state and pressed Back in an inactive window. It now owns both windows in one shared scope, focuses each window before interaction, and closes the first while verifying the second stays usable. All hosting trees detach before final window closure; close is idempotent and global state is restored on errors. A scoped test delegate cancels any unexpected AppKit quit request and records its call stack as a test issue, rather than losing the host. Production explicitly uses [AppKit's last-window policy](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminateafterlastwindowclosed(_:)) to keep the menu-bar app resident. Added tests cover production settings close, multiwindow cleanup, error restoration and termination-request reporting.

The branch was rebased onto main `98978096`, resolving the localization conflict with the acceptance owner's combined version. Static review checked the macOS 13 target, identifier scope, actor isolation, access levels and teardown. No builds, tests, snapshots or remote Mac operations were run for this rework; the precise runtime exit source and successful test completion still require acceptance verification. All screenshot and coverage samples below are historical.

## Earlier validation and limits

Before the final Back toolbar correction, on macOS 26.6.2 with Swift 6.4 and SDK 27:

- The earlier focused set, before adding the Back and lifecycle suites, completed with 130 XCTest and 27 Swift Testing tests passing. The snapshot test also passed and produced the 36 captures above.
- `swift build` passed. No full suite was run.
- Merged focused/snapshot coverage covered 547 of 574 changed executable production lines (95.3%); `coverage-summary.json` records that earlier sample, rather than coverage of the final head.
- Strict SwiftLint on new/rewritten files and the changed shared library passed with zero diagnostics. Existing production files retained 29 legacy diagnostics versus 33 at the base, with no new diagnostics on changed lines. Two unchanged test diagnostics remain. Whole-repository SwiftLint was not clean; see `lint-summary.json`.

After reading the centralization instruction, the in-flight focused rerun was cancelled and no further Mac work was started. Acceptance subsequently reproduced the Back failure; the native Back rework and its new regression tests remain unverified. `git diff --check` and localization-key/placeholder checks were performed locally before the original submission.

## Self-review

Reviewed the complete add/edit/cancel and detail/return/delete paths, whitespace and empty inputs, source preservation, selection cleanup, sparse filter pagination, deletion offsets and generation rejection after clearing. Review found and corrected skipped sparse matches, stale query results after clear, the native SwiftUI table's outline-backed Delete focus handling, toolbar visibility priorities, and a dynamically missing Back item. Following acceptance feedback, Back uses a dedicated native button and is disabled on the list. The native target/action is removed when its representable is dismantled.

The event monitor releases on detach/deinitialization and only handles unmodified Delete in its own focused table, without an attached sheet or text editor. Storage scans use the existing serial background queue and weak model callbacks. User strings cover all five existing locales. No dependencies, credentials or new external data access were added. The acceptance owner still needs to confirm the final build, tests, toolbar return behavior and refreshed screenshot matrix.
