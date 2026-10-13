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
swift test --no-parallel --enable-code-coverage --filter 'ExclusiveUIStateTraitTests|ExclusiveUIStateLanguageTests|LauncherSettingsPolishTests|SettingsPolishTests|SettingsWindowLifecycleTests|TypefluxNavigationTestSupportTests|DockVisibilityControllerTests|TypefluxNavigationInteractionTests|TypefluxPresentationInteractionTests|HistorySettingsBackButtonTests|VocabularyHistorySettingsTests|HistorySettingsQueryTests|VocabularyFilterTests|TypefluxTableDeleteKeyTests|TypefluxWindowTitleLifecycleTests|TypefluxUIControlsTableTests|VocabularyStoreTests|VocabularyStoreExtendedTests|SettingsViewModelHistoryAudioTests|HistoryProcessingDiagnosticsTests|HistoryRetryPlanTests|HistoryExportDestinationTests|FileHistoryStoreTests|SQLiteHistoryStoreTests|SettingsWindowNavigationTests|SettingsSearchScopeTests|SettingsOrganizationTests|StudioHistoryRowLayoutTests|VoiceInputNavigationTests' 2>&1 | tee artifacts/gul349-full.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-full.log &&
rg -q 'Test "window mode previews fit narrow panes and selection persists" passed' artifacts/gul349-full.log &&
rg -q 'Test run with .* passed' artifacts/gul349-full.log &&
TYPEFLUX_VOCABULARY_HISTORY_SNAPSHOTS="$PWD/artifacts/gul349-snapshots" swift test --no-parallel --enable-code-coverage --filter VocabularyHistorySnapshotTests 2>&1 | tee artifacts/gul349-snapshots.log &&
rg -q 'Test run with .* passed' artifacts/gul349-snapshots.log
```

The snapshot command captures Vocabulary, unmatched search, empty library, add sheet, History date groups, record details, pipeline stages and unmatched audio filter in Classic/Liquid Glass × light/dark. It also captures Liquid Glass with Reduce Transparency and Increase Contrast in both appearances. Check the history Back button after opening a record, including a narrow window's native toolbar overflow. The tests use synthetic data and isolated defaults/storage, and restore the localization and vocabulary fixture.

For the window-lifecycle rework, start by running both Back tests together, then the two-window test alone. Require the two-window result and the Swift Testing summary in each log; a zero exit code alone did not establish completion in acceptance rounds 3–5.

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter HistorySettingsBackButtonTests 2>&1 | tee artifacts/gul349-back-sequential.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-back-sequential.log &&
rg -q 'Test run with .* passed' artifacts/gul349-back-sequential.log &&
swift test --no-parallel --filter 'Back in one settings window' 2>&1 | tee artifacts/gul349-back-isolated.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-back-isolated.log &&
rg -q 'Test run with .* passed' artifacts/gul349-back-isolated.log
```

Then check fixture cleanup and related settings behavior:

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter 'SettingsWindowLifecycleTests|SettingsWindowNavigationTests|TypefluxNavigationTestSupportTests|HistorySettingsBackButtonTests|VocabularyHistorySettingsTests|LauncherSettingsPolishTests' 2>&1 | tee artifacts/gul349-window-lifecycle.log &&
rg -q 'Test "Back in one settings window leaves another window detail selected" passed' artifacts/gul349-window-lifecycle.log &&
rg -q 'Test "shared Dock window closures keep the UI test host present" passed' artifacts/gul349-window-lifecycle.log &&
rg -q 'Test "window mode previews fit narrow panes and selection persists" passed' artifacts/gul349-window-lifecycle.log &&
rg -q 'Test run with .* passed' artifacts/gul349-window-lifecycle.log
```

Also run the vocabulary/history and Launcher window tests together without the Back suite, matching acceptance round 5's bisection:

```bash
set -o pipefail
mkdir -p artifacts
swift test --no-parallel --filter 'VocabularyHistorySettingsTests|LauncherSettingsPolishTests' 2>&1 | tee artifacts/gul349-without-back.log &&
rg -q 'Test "history search filter navigation and deletion preserve a complete list" passed' artifacts/gul349-without-back.log &&
rg -q 'Test "window mode previews fit narrow panes and selection persists" passed' artifacts/gul349-without-back.log &&
rg -q 'Test run with .* passed' artifacts/gul349-without-back.log
```

## Return-navigation rework

The acceptance owner's second pass built latest main + PR #455 and passed 131 XCTest tests and the original return-navigation test, but the new Back test still reported an enabled button on the list and a rejected accessibility press. The main-actor factory correction from `1323d73` is retained.

Back now hosts its real `NSButton` inside a generic native view in a dedicated navigation `ToolbarItem`. The contents receive `.disabled` when no selected record is being presented; each representable update applies that environment to the child button and restores its coordinator, target and action. The target is bound to the presenting window's selection and cleared on teardown. Tests resolve the hosted control again after toolbar updates, check its identifier/target/selector, and verify native and accessibility presses by their navigation effects. They also cover disabled state, record deletion, section scope and two-window isolation.

Acceptance round 3 confirmed the Back effect checks pass, but the Swift Testing process exited before producing a result for the two-window test. The changes from `8233a3f6` and `65f27653` are retained: both localization additions survive, and toolbar AX presses are checked by their navigation effect rather than AppKit's Boolean return value.

Acceptance round 5 showed the exit persists after restoring main's fixtures and even when the Back suite is excluded. The earlier fixture changes did not establish the exit's cause. The latest rework removes this PR's toolbar-priority writes from the shared title bridge: `TypefluxWindow`, `TypefluxWindowTitleBridge` and their title-lifecycle test are identical to main again. Native Back stays in its dedicated toolbar item, with the accepted target/action implementation.

The test host now holds a retained presentation token in the actual shared `DockVisibilityController` for the entire process. Other production controllers that use `.shared` can show/close windows without treating the runner as having no presentations and switching it to `.accessory`. The `.exclusiveUIState` trait prepares the host before all participating UI suites, including ones with separate window helpers. The runner's delegate stays intact. Activation policy is initialized once; AX is enabled if a legacy fixture disabled it. The Launcher helper uses this setup and detaches its hosting tree before closing instead of disabling AX after each render. The table-control test also uses shared fixture preparation.

Single-window hosting delegates to the multiwindow helper; teardown detaches hosting trees, orders windows out and closes them without hiding the application. Added regression coverage exercises eight show/close cycles through the real shared Dock controller and checks a following window, in addition to consecutive single/multiwindow scopes, idempotent close and throwing-body cleanup. Independent Dock controller tests still cover the production last-window `.accessory` behavior using their injected policy controller.

The two-window Back test seeds each `StudioView`'s independent initial history selection. Its earlier readiness wait read both windows' AX details before focusing the first; it now focuses and checks each window separately. After Back closes the first detail and its window, it focuses the second before asserting its detail and Back remain usable. The single-window test retains real navigation-row accessibility selection. Named readiness waits and focus/control diagnostics identify the actual phase if acceptance finds another timeout.

Production settings close contains no application-quit call and explicitly uses AppKit's last-window policy to keep the menu-bar app resident. Its lifecycle and navigation tests now inject Dock policy controllers backed by a test double, exercising the real close handler and resource release without changing the host's activation policy. Navigation tests also drop their per-test activation-policy restore. Existing production callers use the shared Dock controller.

The acceptance owner's main merge and both experimental reverts were pulled. The settings initializer keeps `imageSettingsModel:` and `initialHistoryID:`, and the fixed-height lists keep agent/launcher plus vocabulary/history. Main is `bcd424bd`. Static review checked the macOS 13 target, identifier scope, actor isolation, access levels and teardown. No builds, tests, snapshots or remote Mac operations were run for this rework; the exit's precise runtime source and successful completion still require acceptance verification. All screenshot and coverage samples below are historical.

## Window lifecycle source audit

| Path | Appearance/teardown behavior |
| --- | --- |
| `StudioView` / `StudioShell` | Existing localization/permission refresh, account tasks, and sidebar-width handling; added history selection and viewport layout. No added Dock registration, window-close notification, application hide or termination. |
| History / Vocabulary pages | History load-more appearance schedules storage paging; the vocabulary sheet appearance focuses its field. Back dismantling clears its button target/action; the table bridge removes its local event monitor. These paths do not close or hide windows. |
| `TypefluxWindow` / title bridge | Restored to main, including its existing title/toolbar observations and stop-on-detach behavior. No PR-specific toolbar priority or toolbar-removal behavior. |
| `SettingsWindowController` | Existing show/close hooks use an injected Dock controller. Close detaches the hosting tree and releases the window/model as on main. Tests inject policy doubles; the process-level Dock presentation also covers other shared production controllers. |
| `DockVisibilityController` / application entry | Dock production code is unchanged from main: last tracked presentation selects `.accessory`. The test host is now a tracked presentation until process exit. Production `AppDelegate` explicitly keeps the menu-bar app resident after last-window close; startup's accessory policy and development launcher's exit path are unchanged and not invoked by these views. |

## Earlier validation and limits

Before the final Back toolbar correction, on macOS 26.6.2 with Swift 6.4 and SDK 27:

- The earlier focused set, before adding the Back and lifecycle suites, completed with 130 XCTest and 27 Swift Testing tests passing. The snapshot test also passed and produced the 36 captures above.
- `swift build` passed. No full suite was run.
- Merged focused/snapshot coverage covered 547 of 574 changed executable production lines (95.3%); `coverage-summary.json` records that earlier sample, rather than coverage of the final head.
- Strict SwiftLint on new/rewritten files and the changed shared library passed with zero diagnostics. Existing production files retained 29 legacy diagnostics versus 33 at the base, with no new diagnostics on changed lines. Two unchanged test diagnostics remain. Whole-repository SwiftLint was not clean; see `lint-summary.json`.

After reading the centralization instruction, the in-flight focused rerun was cancelled and no further Mac work was started. Acceptance round 3 subsequently confirmed the Back action effects; the current fixture-lifetime and two-window changes remain unverified. `git diff --check` and localization-key/placeholder checks were performed locally before the original submission.

## Self-review

Reviewed the complete add/edit/cancel and detail/return/delete paths, whitespace and empty inputs, source preservation, selection cleanup, sparse filter pagination, deletion offsets and generation rejection after clearing. Review found and corrected skipped sparse matches, stale query results after clear, the native SwiftUI table's outline-backed Delete focus handling and a dynamically missing Back item. Following acceptance feedback, Back uses a dedicated native button and is disabled on the list. The native target/action is removed when its representable is dismantled. Toolbar overflow follows main's native layout again; acceptance should recheck source segments and add/actions in a narrow window.

The event monitor releases on detach/deinitialization and only handles unmodified Delete in its own focused table, without an attached sheet or text editor. Storage scans use the existing serial background queue and weak model callbacks. User strings cover all five existing locales. No dependencies, credentials or new external data access were added. The acceptance owner still needs to confirm the final build, tests, toolbar return behavior and refreshed screenshot matrix.
