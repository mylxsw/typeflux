General, Appearance, Shortcuts, Advanced and Account now use native grouped forms and TypefluxUI controls. Settings tabs use a segmented control. Reset and delete actions require an alert confirmation, and the existing store, recorder, password and billing paths remain in use.

The window title leads the detail toolbar. The bridge preserves the window title for accessibility and the Window menu, suppresses the duplicate title above the sidebar, and removes only the title item from AppKit's centered toolbar identifiers. Its observations stop when the view detaches.

## Evidence

The four style/appearance combinations are produced by `SettingsPagesSnapshotTests` and the real-window `SettingsWindowSnapshotTests`. All account data is synthetic. Content snapshots use the reusable bitmap renderer; window captures include WindowServer's navigation compositor. Both before and after windows use 1100 × 800 content sizing.

| Page | Classic light | Classic dark | Liquid Glass light | Liquid Glass dark |
| --- | --- | --- | --- | --- |
| General | [PNG](pages/general-classic-light.png) | [PNG](pages/general-classic-dark.png) | [PNG](pages/general-liquidGlass-light.png) | [PNG](pages/general-liquidGlass-dark.png) |
| Appearance | [PNG](pages/appearance-classic-light.png) | [PNG](pages/appearance-classic-dark.png) | [PNG](pages/appearance-liquidGlass-light.png) | [PNG](pages/appearance-liquidGlass-dark.png) |
| Advanced | [PNG](pages/advanced-classic-light.png) | [PNG](pages/advanced-classic-dark.png) | [PNG](pages/advanced-liquidGlass-light.png) | [PNG](pages/advanced-liquidGlass-dark.png) |
| Shortcuts | [PNG](pages/shortcuts-classic-light.png) | [PNG](pages/shortcuts-classic-dark.png) | [PNG](pages/shortcuts-liquidGlass-light.png) | [PNG](pages/shortcuts-liquidGlass-dark.png) |
| Account | [PNG](pages/account-classic-light.png) | [PNG](pages/account-classic-dark.png) | [PNG](pages/account-liquidGlass-light.png) | [PNG](pages/account-liquidGlass-dark.png) |

The title comparison uses the vocabulary destination in the settings window, matching the GUL-346 baseline. The live title test also checks Settings and Account.

| Window | Before | After |
| --- | --- | --- |
| Classic light | [PNG](before/settings-classic-light.png) | [PNG](after/settings-classic-light.png) |
| Classic dark | [PNG](before/settings-classic-dark.png) | [PNG](after/settings-classic-dark.png) |
| Liquid Glass light | [PNG](before/settings-liquidGlass-light.png) | [PNG](after/settings-liquidGlass-light.png) |
| Liquid Glass dark | [PNG](before/settings-liquidGlass-dark.png) | [PNG](after/settings-liquidGlass-dark.png) |

Accessibility environment overrides: Reduce Transparency [light](after/reduce-transparency-light.png) / [dark](after/reduce-transparency-dark.png), Increase Contrast [light](after/increase-contrast-light.png) / [dark](after/increase-contrast-dark.png). The token matrix tests exercise all capability and accessibility combinations; the settings slider tests verify disabled adjustment and the explanatory label under either override.

## Validation

Executed on the connected mac-mini.local worker through macrun: macOS 26.6.2, Swift 6.4, SDK 27. The full suite was not run, as required by GUL-347; the parent acceptance run owns it. macOS 13–15 fallbacks are covered by capability tests and availability guards, but were not exercised on an older live Mac. Native content controls use the host OS's styling in both interface styles.

```bash
swift build
swift build --enable-code-coverage

TYPEFLUX_SETTINGS_WINDOW_SNAPSHOTS="$PWD/artifacts/after" \
TYPEFLUX_SETTINGS_PAGES_SNAPSHOTS="$PWD/artifacts/pages" \
swift test --no-parallel --enable-code-coverage --filter 'GroupedSettingsBehaviorTests|AppearanceSettingsTests|HotkeySettingsViewTests|SettingsBehaviorTests|SettingsOrganizationTests|AccountViewRenderingTests|AccountViewOperationTests|AccountViewCloudDataSyncVisibilityTests|BillingOperationBehaviorTests|SettingsViewModelTextTransformationTests|SettingsViewModelHotkeyTests|SettingsStoreAudioTests|AskLauncherPositionSettingsTests|HotkeyRecorderTests|HotkeyFormatTests|HotkeyConflictCheckerTests|KeywordHotkeyTests|TypefluxUIControlsBehaviorTests|TypefluxUITokenTests|ExclusiveUIStateLanguageTests|SettingsWindowNavigationTests|SettingsWindowSnapshotTests|SettingsPagesSnapshotTests|TypefluxWindowTitleLifecycleTests'

TYPEFLUX_HOTKEY_MENUS=1 swift test --no-parallel --enable-code-coverage --filter HotkeySettingsConfirmationTests
swift test --no-parallel --enable-code-coverage --filter 'PasswordChangeSuccessSheetTests|ExclusiveUIStateLanguageTests'

swiftlint lint Sources/TypefluxUI --strict --reporter json
xargs swiftlint lint --strict --reporter json < artifacts/lint-files.txt
xargs swiftlint lint --strict --reporter json < artifacts/lint-main-files.txt
swiftlint lint Tests/TypefluxTests/HotkeySettingsConfirmationTests.swift Tests/TypefluxTests/PasswordChangeSuccessSheetTests.swift Sources/Typeflux/Settings/HotkeySettingsView.swift --strict --reporter json
```

Both builds passed. The related filter passed 52 XCTest tests and 76 Swift Testing tests in 17 suites. The dedicated native menu test passed one XCTest test, checking cancel/confirm for reset, unset and deletion. The password-success and isolation filter passed 11 tests. Native menus use XCTest in a dedicated process because menu tracking can prematurely end the Swift Testing runner; an exit code without a test completion marker is not counted as a pass.

Strict library lint passed with zero violations in 85 files. The 34 changed Swift files have 33 existing diagnostics, compared with 36 on main, with **zero new diagnostics**. The new files and final additional checks pass strict lint. Existing TODO and length diagnostics remain in the legacy files; no lint baseline or rules were changed. See [lint-summary.json](lint-summary.json).

Coverage is **674/728 added or modified executable production lines (92.58%)**, measured from `git diff --unified=0` against `029f3fed`. New production files count in full. Lines without LLVM execution records, including comments and environment property wrappers, do not enter the denominator. [coverage-summary.json](coverage-summary.json) includes per-file uncovered lines.

SwiftPM writes raw profiles to `.build/out/Products/Debug/codecov` and clears that directory between test runs, overriding a caller-supplied `LLVM_PROFILE_FILE`. Each successful run's profiles were merged before the next run. Only the three successful filters above contribute: the related run uses instrumentation signature `16052354917892043752`, and the final menu/password runs use `16053243400639689704`. The production function counter signatures are compatible; merge/export reported no counter mismatches. Failed or prematurely terminated menu attempts are excluded.

```bash
xcrun llvm-profdata merge -sparse artifacts/accepted.profdata artifacts/menu.profdata \
  .build/out/Products/Debug/codecov/*.profraw -o artifacts/final.profdata
xcrun llvm-cov export .build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests \
  --instr-profile=artifacts/final.profdata --format=lcov > artifacts/coverage.lcov
```

## Self-review

Checked every migrated preference and conditional row against the original bindings, recorder cleanup, keyword save/conflict behavior, account loading/signed-out/subscription states, billing retry/cancellation/session replacement, password validation and logout. Tests press the actual native switches, segments, secure fields, menu commands and alert buttons. Library tests cover keyboard actions and slider edits. Title observations and scheduled callbacks use weak references and stop after detachment.

Fixed stale native form labels after language changes, the duplicate slider title found in screenshot review, and the title's caption/centering resets during SwiftUI toolbar updates. Server health labels retain the original `lastError` rule. Rechecked cancellation without mutation for every new destructive alert, no removed-component references, no hard-coded fonts/radii/colors in the migrated pages, no added dependencies or secrets, and `git diff --check`.
