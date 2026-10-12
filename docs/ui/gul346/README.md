GUL-346 moves the production settings window onto `TypefluxWindow`. The native split view owns the sidebar, titles live in the toolbar, and each filterable list uses the shared collapsible search. Existing page actions, sidebar order, and account hover/click behavior are preserved.

## Evidence

`before/` captures the production controller on main at `22e78257`; `after/` captures the changed controller. Both use 1100 × 800 content sizing. The new native toolbar adds 52 pixels to the captured window height. Fixtures contain synthetic data and restore shared vocabulary defaults after use.

| Appearance | Before | After | Expanded search |
| --- | --- | --- | --- |
| Classic light | [Before](before/settings-classic-light.png) | [After](after/settings-classic-light.png) | [Search](after/search-classic-light.png) |
| Classic dark | [Before](before/settings-classic-dark.png) | [After](after/settings-classic-dark.png) | [Search](after/search-classic-dark.png) |
| Liquid Glass light | [Before](before/settings-liquidGlass-light.png) | [After](after/settings-liquidGlass-light.png) | [Search](after/search-liquidGlass-light.png) |
| Liquid Glass dark | [Before](before/settings-liquidGlass-dark.png) | [After](after/settings-liquidGlass-dark.png) | [Search](after/search-liquidGlass-dark.png) |

The Liquid Glass sidebar uses the system panel without an extra glass container or inset. Classic uses an opaque sidebar on macOS 26. Accessibility captures use the production view with strengthened `TypefluxAccessibilityOptions`; Increase Contrast also uses AppKit's high contrast appearance. These captures do not change global OS preferences.

- Reduce Transparency: [light](after/reduce-transparency-light.png), [dark](after/reduce-transparency-dark.png).
- Increase Contrast: [light](after/increase-contrast-light.png), [dark](after/increase-contrast-dark.png).
- Destructive button and navigation icon tokens: [Classic light](controls/content-overview-classic-light.png), [Classic dark](controls/content-overview-classic-dark.png), [Liquid Glass light](controls/content-overview-liquidGlass-light.png), [Liquid Glass dark](controls/content-overview-liquidGlass-dark.png).

## Validation

Run on the connected Mac with macOS 26.6.2, Swift 6.4 and SDK 27. Only related tests were run; the full suite remains deferred to parent acceptance. macOS 13–15 material policy is unit tested, but no older OS worker was available for a live capture.

```sh
swift build --enable-code-coverage

TYPEFLUX_UI_NAVIGATION_LIVE=1 swift test --enable-code-coverage --filter 'SettingsWindowNavigationTests|SettingsWindowListSearchTests|SettingsSidebarChromeTests|TypefluxNavigationInteractionTests'

swift test --enable-code-coverage --filter 'SettingsSearchScopeTests|SettingsPolishTests|AgentSettingsRedesignTests|LauncherSettingsPolishTests|MemoryNotesInteractionTests|AskMemoryNotesSettingsTests|ModelSettingsPresentationTests|SettingsOrganizationTests|VoiceInputNavigationTests|StudioThemeTests|StudioOverviewPanelTests|StatusBarFeedbackTests|TypefluxUITokenTests|TypefluxUIControlsBehaviorTests|TypefluxUIControlStateTests|TypefluxNavigationStateTests|ExclusiveUIStateLanguageTests'

swift test --enable-code-coverage --filter 'SettingsOrganizationTests|ExclusiveUIStateLanguageTests'

swift test --enable-code-coverage --filter 'SettingsSearchScopeTests|TypefluxUITokenTests|TypefluxUIControlsBehaviorTests|TypefluxUIControlStateTests|SettingsPolishTests|AgentSettingsRedesignTests|LauncherSettingsPolishTests|SettingsOrganizationTests|ExclusiveUIStateLanguageTests'

TYPEFLUX_SETTINGS_WINDOW_SNAPSHOTS=$PWD/artifacts/after swift test --enable-code-coverage --filter SettingsWindowSnapshotTests

TYPEFLUX_UI_SNAPSHOTS=$PWD/artifacts/controls swift test --enable-code-coverage --filter TypefluxUIControlsVisualTests

swiftlint lint Sources/TypefluxUI --strict
swiftlint lint Sources --strict --baseline .swiftlint-baseline.json --reporter json
```

Final build passed. The final native filter passed 16 tests, the window snapshot filter passed two tests, and the final related regression filter passed 27 XCTest tests plus 44 Swift Testing tests. Strict library lint passed with zero violations in 84 files.

The earlier wider regression run exercised 68 XCTest tests (one intentional skip) and 53 Swift Testing tests. It initially found obsolete in-content title assertions and an audit that did not recognize multiline suite traits. Both were corrected; the smallest retry passed all 14 tests. The controls snapshot suite passed all three tests.

Whole-repository strict lint has existing failures on main. Compare diagnostics by relative source file, rule, and normalized reason so line movement does not count as a new warning. Main reports 1,835 existing diagnostics; the final source reports 1,833, with zero new diagnostics. No lint baseline was changed.

Coverage is measured on added or modified instrumentable production lines from `git diff --unified=0`. Coverage is **483/506 lines (95.45%)**. Only seven raw profiles matching the final instrumentation signature `3219110316196018445` are included; merge/export reports no counter mismatches. Profiles from earlier development binaries are excluded. These profiles are merged with `xcrun llvm-profdata merge -sparse`, then exported with `xcrun llvm-cov export --format=lcov` against the instrumented test executable. See [coverage-summary.json](coverage-summary.json) for the measured denominator and uncovered lines. Environment `@Entry` declarations have no executable coverage records.

## Self-review

Checked all nine page destinations, grouped sidebar navigation, default/minimum window sizes, localized titles, search scope changes, empty/no-result lists, and account/promo states. Native interaction tests exercise ⌘F, clear-then-collapse Esc, blur retention, marked-text composition, unrelated windows and attached sheets.

Fixed immediate field-editor resignation on collapsed search, toolbar placement when no other actions exist, shared-defaults isolation in UI fixtures, and native AX traversal for outline rows. Closing the controller detaches its hosting tree; search monitors/observers and appearance observers are released. Reviewed query flow for reentrancy, labels and keyboard actions, and the diff for accidental dependencies, secrets, unrelated formatting, and obsolete component references.
