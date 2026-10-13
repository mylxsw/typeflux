Models now uses TypefluxUI grouped forms, native provider lists and searchable borderless scene pop-ups. Scenes, Providers and Local models live in the toolbar centre; Voice Input uses the same native segmented control and retains its page actions. Provider drafts, saving, connection tests, catalog loading, model capabilities and download confirmations retain their existing store and service paths.

The retired model styles, custom fields, menus and tab bars have no remaining references. Their consumers on later settings pages use native controls and existing shared containers.

## Evidence

`ModelSettingsSnapshotTests` captures 36 images with isolated settings, synthetic model data and no provider requests. Main windows and the selection menu use WindowServer captures on the worker's available desktop, including the native collapsed-sidebar layout at narrow widths; catalogs and endpoint sheets use the shared bitmap renderer with the opaque glass fallback. Content stays solid in both styles. Native controls reflect the macOS host's styling.

| Surface | Classic light | Classic dark | Liquid Glass light | Liquid Glass dark |
| --- | --- | --- | --- | --- |
| Scenes | [PNG](snapshots/scenes-classic-light.png) | [PNG](snapshots/scenes-classic-dark.png) | [PNG](snapshots/scenes-liquidGlass-light.png) | [PNG](snapshots/scenes-liquidGlass-dark.png) |
| Providers | [PNG](snapshots/providers-classic-light.png) | [PNG](snapshots/providers-classic-dark.png) | [PNG](snapshots/providers-liquidGlass-light.png) | [PNG](snapshots/providers-liquidGlass-dark.png) |
| Local models | [PNG](snapshots/local-classic-light.png) | [PNG](snapshots/local-classic-dark.png) | [PNG](snapshots/local-liquidGlass-light.png) | [PNG](snapshots/local-liquidGlass-dark.png) |
| Language provider | [PNG](snapshots/provider-classic-light.png) | [PNG](snapshots/provider-classic-dark.png) | [PNG](snapshots/provider-liquidGlass-light.png) | [PNG](snapshots/provider-liquidGlass-dark.png) |
| Speech provider | [PNG](snapshots/speech-provider-classic-light.png) | [PNG](snapshots/speech-provider-classic-dark.png) | [PNG](snapshots/speech-provider-liquidGlass-light.png) | [PNG](snapshots/speech-provider-liquidGlass-dark.png) |
| Cloud provider | [PNG](snapshots/cloud-classic-light.png) | [PNG](snapshots/cloud-classic-dark.png) | [PNG](snapshots/cloud-liquidGlass-light.png) | [PNG](snapshots/cloud-liquidGlass-dark.png) |
| Selection menu | [PNG](snapshots/picker-classic-light.png) | [PNG](snapshots/picker-classic-dark.png) | [PNG](snapshots/picker-liquidGlass-light.png) | [PNG](snapshots/picker-liquidGlass-dark.png) |
| Catalog | [PNG](snapshots/catalog-classic-light.png) | [PNG](snapshots/catalog-classic-dark.png) | [PNG](snapshots/catalog-liquidGlass-light.png) | [PNG](snapshots/catalog-liquidGlass-dark.png) |
| Add endpoint | [PNG](snapshots/endpoint-classic-light.png) | [PNG](snapshots/endpoint-classic-dark.png) | [PNG](snapshots/endpoint-liquidGlass-light.png) | [PNG](snapshots/endpoint-liquidGlass-dark.png) |

## Validation

Executed on mac-mini.local through macrun: macOS 26.6.2, Swift 6.4, SDK 27. Only related test classes were run. Older live macOS versions were not available; capability and accessibility fallback tests cover the shared tokens.

```bash
swift build
TYPEFLUX_ASK_SNAPSHOTS=/tmp/typeflux-gul348-ask \
TYPEFLUX_SKILL_SNAPSHOTS=/tmp/typeflux-gul348-skills \
TYPEFLUX_PROTOCOL_SNAPSHOTS=/tmp/typeflux-gul348-protocol \
TYPEFLUX_MEMORY_NOTES_SNAPSHOTS=/tmp/typeflux-gul348-memory \
swift test --build-system native --no-parallel --enable-code-coverage \
  --filter 'ModelSettingsPresentationTests|ModelRegistryTests|ProviderModelCatalogTests|ModelProtocolTests|ModelProtocolHTTPTests|ModelProtocolRenderTests|ModelPageTabTests|ModelScenePopupTests|ModelSettingsControlsTests|ModelProviderFormTests|SettingsSearchScopeTests|SettingsWindowNavigationTests|SettingsPolishTests|LauncherSettingsPolishTests|AgentSettingsRedesignTests|AskWorkflowEditorVisualTests|WorkflowGalleryVisualTests|AskImageSettingsTests|AskCloudflareSettingsVisualTests|AskSkillSettingsVisualTests|MemoryNotesInteractionTests|VoiceInputNavigationTests|ClipboardSettingsTests|ClipboardDataSettingsTests|AskImageRecoveryCopyTests|AskModelChooserImageTests|AskMemoryNotesSettingsTests|AskBrowserSearchTests|AskLauncherFeatureSearchTests|AskWorkflowEditorTests|TypefluxUIControlsBehaviorTests|TypefluxUITokenTests'

TYPEFLUX_SETTINGS_MENU_TESTS=1 \
swift test --build-system native --no-parallel --enable-code-coverage \
  --filter TypefluxPopupMenuTests/testSharedAndStudioPickersShowOptionsDirectlyAndUpdateSelection
TYPEFLUX_SETTINGS_MENU_TESTS=1 \
swift test --build-system native --no-parallel --enable-code-coverage \
  --filter TypefluxPopupMenuTests/testUnavailableSelectionKeepsItsLabelUntilAValidOptionIsChosen
TYPEFLUX_MODEL_SNAPSHOTS=/tmp/typeflux-gul348-snapshots \
swift test --build-system native --no-parallel --enable-code-coverage --filter ModelSettingsSnapshotTests

swiftlint lint Sources/TypefluxUI --strict --reporter json
xargs swiftlint lint --strict --reporter json < artifacts/lint-files.txt
```

`swift build` passed (143.33 seconds). The regular filter passed 159 XCTest tests and 145 Swift Testing tests. The two isolated menu tests and the snapshot test each passed in their own process: **307 tests passed with no skips or failures**. Changed-line coverage is **1,216/1,403 (86.67%)**.

Strict library lint and the five new or rewritten test files pass with zero violations. The 62 changed production Swift files retain 78 existing legacy diagnostics, compared with 96 on main; no diagnostics occur on modified lines and no file/rule count increases. The lint configuration and baseline are unchanged. See [lint-summary.json](lint-summary.json).

Coverage counts added or modified executable production lines against `374f6d3d366dc0eb72df125a2af815a6d14b57bf`, using `git diff --unified=0`; new production files count in full. Comments, declarations and property wrappers without LLVM execution records do not enter the denominator. Failed and prematurely terminated attempts are excluded. [coverage-summary.json](coverage-summary.json) records per-file uncovered lines.

```bash
xcrun llvm-profdata merge -sparse artifacts/regular.profdata artifacts/selection-menu.profdata \
  artifacts/unavailable-menu.profdata \
  artifacts/snapshots.profdata -o artifacts/accepted.profdata
xcrun llvm-cov export \
  .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests \
  --instr-profile=artifacts/accepted.profdata --format=lcov > artifacts/coverage.lcov
```

Native menu tracking runs in separate XCTest processes because it can prematurely end the Swift Testing host or interfere with other native windows. Each successful run's profiles are merged and saved before SwiftPM clears the coverage directory for the next run. Test completion markers are checked in addition to exit codes.

## Self-review

Checked scene eligibility and persistence, remote/local routing, empty searches and missing saved selections, provider draft resets, save/test/load actions, catalog exclusions, capability and deletion actions, local download confirmation/cancellation, toolbar placement and keyboard controls. Menu updates stay deferred during tracking, redundant installs are skipped, search clears propagate to the native field, and pending updates stop on detachment. Provider operations retain cancellation when the detail closes.

Fixed the loss of Voice Input page actions, duplicate native form labels, accessibility grouping that hid child controls, and suggestion-button overlap after retiring the custom field padding. Domain links preserve their focused domain; tab content resets its scroll state without restarting the catalog task. Test fixtures use isolated defaults and an in-memory keychain. Checked no retired-component references, added dependencies or secrets, and `git diff --check`.
