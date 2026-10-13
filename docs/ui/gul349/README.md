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
set -o pipefail
mkdir -p artifacts
swift build &&
swift test --no-parallel --enable-code-coverage --filter 'SettingsBehaviorTestSupportTests|TypefluxUIControlsBehaviorTests|ExclusiveUIStateTraitTests|ExclusiveUIStateLanguageTests|LauncherSettingsPolishTests|SettingsPolishTests|SettingsWindowLifecycleTests|TypefluxNavigationTestSupportTests|DockVisibilityControllerTests|TypefluxNavigationInteractionTests|TypefluxPresentationInteractionTests|HistorySettingsBackButtonTests|VocabularyHistorySettingsTests|HistorySettingsQueryTests|VocabularyFilterTests|TypefluxTableDeleteKeyTests|TypefluxWindowTitleLifecycleTests|TypefluxUIControlsTableTests|VocabularyStoreTests|VocabularyStoreExtendedTests|SettingsViewModelHistoryAudioTests|HistoryProcessingDiagnosticsTests|HistoryRetryPlanTests|HistoryExportDestinationTests|FileHistoryStoreTests|SQLiteHistoryStoreTests|SettingsWindowNavigationTests|SettingsSearchScopeTests|SettingsOrganizationTests|StudioHistoryRowLayoutTests|VoiceInputNavigationTests' 2>&1 | tee artifacts/gul349-full.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-full.log &&
rg -q 'Test "window mode previews fit narrow panes and selection persists" passed' artifacts/gul349-full.log &&
rg -q 'Executed [0-9]+ tests?, with 0 failures' artifacts/gul349-full.log &&
rg -q '✔ Test run with .* passed' artifacts/gul349-full.log &&
TYPEFLUX_VOCABULARY_HISTORY_SNAPSHOTS="$PWD/artifacts/gul349-snapshots" swift test --no-parallel --enable-code-coverage --filter VocabularyHistorySnapshotTests 2>&1 | tee artifacts/gul349-snapshots.log &&
rg -q 'Executed [0-9]+ tests?, with 0 failures' artifacts/gul349-snapshots.log &&
rg -q '✔ Test run with .* passed' artifacts/gul349-snapshots.log
```

The snapshot command captures Vocabulary, unmatched search, empty library, add sheet, History date groups, record details, pipeline stages and unmatched audio filter in Classic/Liquid Glass × light/dark. It also captures Liquid Glass with Reduce Transparency and Increase Contrast in both appearances. Check the history Back button after opening a record, including a narrow window's native toolbar overflow. The tests use synthetic data and isolated defaults/storage, and restore the localization and vocabulary fixture.

For the window-lifecycle rework, start by running both Back tests together, then the two-window test alone. Require the two-window result, XCTest zero failures and the Swift Testing summary in each log; a zero exit code alone did not establish completion in acceptance rounds 3–6.

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter HistorySettingsBackButtonTests 2>&1 | tee artifacts/gul349-back-sequential.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-back-sequential.log &&
rg -q 'Executed [0-9]+ tests?, with 0 failures' artifacts/gul349-back-sequential.log &&
rg -q '✔ Test run with .* passed' artifacts/gul349-back-sequential.log &&
swift test --no-parallel --filter 'Back in one settings window' 2>&1 | tee artifacts/gul349-back-isolated.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-back-isolated.log &&
rg -q 'Executed [0-9]+ tests?, with 0 failures' artifacts/gul349-back-isolated.log &&
rg -q '✔ Test run with .* passed' artifacts/gul349-back-isolated.log
```

Check the unchanged XCTest navigation regression separately:

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter VoiceInputNavigationTests 2>&1 | tee artifacts/gul349-voice-navigation.log &&
rg -q 'testVocabularyActionRemainsAvailableBelowToolbarTabs.*passed' artifacts/gul349-voice-navigation.log &&
rg -q 'Executed 8 tests, with 0 failures' artifacts/gul349-voice-navigation.log &&
rg -q '✔ Test run with .* passed' artifacts/gul349-voice-navigation.log
```

Then check fixture cleanup and related settings behavior:

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter 'SettingsBehaviorTestSupportTests|TypefluxUIControlsBehaviorTests|VoiceInputNavigationTests|SettingsWindowLifecycleTests|SettingsWindowNavigationTests|TypefluxNavigationTestSupportTests|HistorySettingsBackButtonTests|VocabularyHistorySettingsTests|LauncherSettingsPolishTests' 2>&1 | tee artifacts/gul349-window-lifecycle.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-window-lifecycle.log &&
rg -q 'Test "shared Dock window closures keep the UI test host present" passed' artifacts/gul349-window-lifecycle.log &&
rg -q 'Test "window mode previews fit narrow panes and selection persists" passed' artifacts/gul349-window-lifecycle.log &&
rg -q 'Executed [0-9]+ tests?, with 0 failures' artifacts/gul349-window-lifecycle.log &&
rg -q '✔ Test run with .* passed' artifacts/gul349-window-lifecycle.log
```

Also run the vocabulary/history and Launcher window tests together without the Back suite, matching acceptance round 5's bisection:

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter 'VocabularyHistorySettingsTests|LauncherSettingsPolishTests' 2>&1 | tee artifacts/gul349-without-back.log &&
rg -q 'Test "history search filter navigation and deletion preserve a complete list" passed' artifacts/gul349-without-back.log &&
rg -q 'Test "window mode previews fit narrow panes and selection persists" passed' artifacts/gul349-without-back.log &&
rg -q 'Executed [0-9]+ tests?, with 0 failures' artifacts/gul349-without-back.log &&
rg -q '✔ Test run with .* passed' artifacts/gul349-without-back.log
```

## Return-navigation rework

The acceptance owner located and experimentally confirmed the silent exit in lldb: AppKit button `performClick` (including native button AX press) starts a nested `nextEvent` loop. HIToolbox subsequently posts `CFRunLoopStop`, which stops Swift Testing's outer main runloop; Swift's async-main drain exits with 0. The earlier Dock/activation investigations did not identify this root cause.

Back tests now check the real button's target, selector, identifier and enabled state, then use `NSApp.sendAction` through the shared press helper. Native buttons, button cells and switches never take the AX/click path; toggles update state before dispatch, disabled controls retain state, and menu items dispatch directly without tracking. Native toolbar proxies resolve to their hosted controls before the generic SwiftUI AX fallback. Helper regression tests cover original sender identity, disabled controls, checkbox/switch state and button/matrix-cell ownership. Matrix cells use the documented [selection API](https://developer.apple.com/documentation/appkit/nsmatrix/selectcell%28atrow%3Acolumn%3A%29) before action dispatch. Shared keyboard tests inspect native shortcut wiring before action dispatch, and SettingsPolish focuses text fields directly instead of mouse/nextEvent tracking. TypefluxUIControlsBehaviorTests also uses these helpers.

The two-window Back test seeds each root's independent detail selection, checks each owned host/toolbar, dispatches the first Back, and verifies the second stays selected and usable after the first window closes. It no longer waits for `NSApp.keyWindow` or attempts focus switches; the test host does not run `NSApp.run`. The single-window test retains actual navigation-row action dispatch and record-deletion/section-scope coverage.

The New word regression follows removal of native toolbar action priorities in the preceding rework. Primary actions now retain high priority, including native groups whose action appears only in the group label. This keeps New word accessible in the default narrow window alongside the fixed voice-input tabs. The original VoiceInputNavigationTests assertion is unchanged; additional coverage checks a populated 900-point vocabulary window can open/cancel the add sheet and preserve its record. Title bridge metadata observations still stop on detach, and user-priority items are preserved.

The shared application fixture retains its delegate/Dock isolation and repairs AX if an older helper disabled it. These are fixture contracts, not a termination workaround. Production close contains no added quit call; settings controller tests inject their Dock policy dependency. Main is `bcd424bd`, retaining both `imageSettingsModel:` and `initialHistoryID:` and the combined agent/launcher/vocabulary/history layout lists.

No builds, tests, screenshots or macrun were run for this rework. Static review covered macOS 13 APIs, actor/access levels, per-window target ownership, disabled state, menu/keyboard paths and teardown. Acceptance must confirm both XCTest's zero-failure result and `✔ Test run with … passed`, including the unchanged VoiceInput navigation regression. Screenshot and coverage samples below are historical.

## Window lifecycle source audit

| Path | Appearance/teardown behavior |
| --- | --- |
| `StudioView` / `StudioShell` | Existing localization/permission refresh, account tasks, and sidebar-width handling; added history selection and viewport layout. No added Dock registration, window-close notification, application hide or termination. |
| History / Vocabulary pages | History load-more appearance schedules storage paging; the vocabulary sheet appearance focuses its field. Back dismantling clears its button target/action; the table bridge removes its local event monitor. These paths do not close or hide windows. |
| `TypefluxWindow` / title bridge | Existing title/toolbar observations stop on detach. Priorities promote this window's fixed tabs and declared primary action labels, preserving `.user` priorities; no toolbar-removal, window-close, activation or quit action. |
| `SettingsWindowController` | Existing show/close hooks use an injected Dock controller. Close detaches the hosting tree and releases the window/model as on main. Tests inject policy doubles; the process-level Dock presentation also covers other shared production controllers. |
| `DockVisibilityController` / application entry | Dock production code is unchanged from main: last tracked presentation selects `.accessory`. The test host is now a tracked presentation until process exit. Production `AppDelegate` explicitly keeps the menu-bar app resident after last-window close; startup's accessory policy and development launcher's exit path are unchanged and not invoked by these views. |

## Earlier validation and limits

Before the final Back toolbar correction, on macOS 26.6.2 with Swift 6.4 and SDK 27:

- The earlier focused set, before adding the Back and lifecycle suites, completed with 130 XCTest and 27 Swift Testing tests passing. The snapshot test also passed and produced the 36 captures above.
- `swift build` passed. No full suite was run.
- Merged focused/snapshot coverage covered 547 of 574 changed executable production lines (95.3%); `coverage-summary.json` records that earlier sample, rather than coverage of the final head.
- Strict SwiftLint on new/rewritten files and the changed shared library passed with zero diagnostics. Existing production files retained 29 legacy diagnostics versus 33 at the base, with no new diagnostics on changed lines. Two unchanged test diagnostics remain. Whole-repository SwiftLint was not clean; see `lint-summary.json`.

After reading the centralization instruction, the in-flight focused rerun was cancelled and no further Mac work was started. Acceptance round 3 subsequently confirmed the Back action effects; the current action-dispatch and narrow-toolbar changes remain unverified. `git diff --check` and localization-key/placeholder checks were performed locally before the original submission.

## Self-review

Reviewed the complete add/edit/cancel and detail/return/delete paths, whitespace and empty inputs, source preservation, selection cleanup, sparse filter pagination, deletion offsets and generation rejection after clearing. Review found and corrected skipped sparse matches, stale query results after clear, the native SwiftUI table's outline-backed Delete focus handling and a dynamically missing Back item. Following acceptance feedback, Back uses a dedicated native button and is disabled on the list. The native target/action is removed when its representable is dismantled. Primary toolbar actions retain visibility before overflow; acceptance should recheck source segments and add/actions in a narrow window.

The event monitor releases on detach/deinitialization and only handles unmodified Delete in its own focused table, without an attached sheet or text editor. Storage scans use the existing serial background queue and weak model callbacks. User strings cover all five existing locales. No dependencies, credentials or new external data access were added. The acceptance owner still needs to confirm the final build, tests, toolbar return behavior and refreshed screenshot matrix.
