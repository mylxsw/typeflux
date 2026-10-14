# GUL-389 translation P3

P3 remembers collapse choices by service across the panel and launcher, shows two of three retained word-card examples with an expansion action, and keeps UK / US speech actions independent. The copy menu shares its tested actions, including original + translation. Light cards and language fields use the design's bright surfaces. Provider recovery keeps isolated retries and session quota skips; missing-key failures are concise and screenshot originals show the correction hint.

## Native captures

All six scenes are captured in dark and light appearance from actual macOS AppKit / SwiftUI windows. The panel uses its production controller, the launcher uses its production view with an injected plugin session, and settings use the complete production translation settings view. Translation, OCR and credentials are deterministic test fixtures; no live provider or production account is contacted. Design crops are freshly rendered from `docs/design/translation-panel.html` at 2× on Chromium. Each comparison puts design left and native right, dark above light. Native source images and dimensions are retained.

The settings capture keeps the confirmed defaults (unset shortcuts; only device and first AI enabled), while the design demonstrates configured shortcuts and extra providers. Settings chrome follows the existing application's shared components.

## Focused validation

The selected suites cover changed presentation and data limits, directly affected fanout and settings dependencies, native panel sizing / keyboard / screenshots, and the same stack's launcher interactions. No full test run is requested.

All selected tests pass on the configured Mac mini (macOS 26.6.2, Swift 6.4 / Xcode 27). The normal repository coverage runner was used, with the same task-local native Swift shim as P2: `--build-system native`, plus `-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping` when coverage is requested. Repository runner scripts were not changed. All UI suites carry `.exclusiveUIState`.

The commands below ran with these environment values (the Swift shim is task-local):

```bash
export PATH="$PWD/artifacts/bin:$PATH"
export TYPEFLUX_TRANSLATION_PANEL_SNAPSHOTS="$PWD/artifacts/native"
export TYPEFLUX_TRANSLATION_NATIVE=1
```

```bash
# Result operations, fanout, settings dependencies, word-card data/rendering,
# native panel policies and the directly affected launcher interactions.
make coverage \
  SUITE="AskTranslationPolishTests AskTranslationFanoutTests AskTranslationStackViewTests AskTranslationPanelModelTests AskTranslationPanelControllerTests AskTranslationPanelSettingsViewTests AskTranslationSettingsModelTests AskTranslationProviderSheetTests AskWordCardTests AskWordCardViewTests AskWordCardTranslationTests AskWordCardTranslationViewTests AskWordLookupEngineTests AskWordCardLooseReplyTests AskTranslatePluginWordCardTests AskTranslatePluginGarbledCardTests AskTranslationEngineFactoryTests AskTranslatePluginTests" \
  FILTER="AskQuickResultsInteractionTests/translationStack.*"

# After the word-card heading/copy-label visual fixes and unique settings filename.
make coverage \
  SUITE="AskTranslationPolishTests AskTranslationStackViewTests AskTranslationPanelControllerTests AskWordCardViewTests AskWordCardTranslationViewTests AskWordCardLooseReplyTests" \
  FILTER="AskQuickResultsInteractionTests/translationStack.*"

# After the explicit Configure/去配置 label and complete launcher word-book fixture.
make coverage \
  SUITE="AskTranslationPolishTests AskTranslationFanoutTests AskTranslationStackViewTests AskTranslationPanelControllerTests"
```

| Command | Complete command wall time | Result |
|---|---:|---|
| First coverage attempt | 80.29 s | Build stopped at relocated module-cache paths; no tests executed |
| Same scope after cache rebuild | 106.67 s | Build found the missing dynamic AppStorage initialization; corrected |
| Same scope after production fix | 190.93 s | Test build found throwing expressions inside assertion macros; corrected |
| Initial focused scope, including rebuild/discovery/report | **102.34 s** | **94/94 tests in 19 suites passed** |
| Focused UI recheck, including rebuild/discovery/report | **100.11 s** | **37/37 tests in 7 suites passed** |
| Final recovery/capture recheck, including rebuild/discovery/report | **90.17 s** | **22/22 tests in 4 suites passed** |

The runner-only totals for the three successful commands were 97.95 s, 94.91 s and 85.18 s; the table includes shell startup and coverage report generation as measured by the worker. These were rebuilt or verified builds, not reused passing test results. No full suite was run.

[Changed-code coverage](changed-code-coverage.json): **92.31% (180/195 executable added or modified production Swift lines)** against `9e471b52`. This is the conservative measurement from the **final 22-test scope alone**, using fresh profiles; the standalone card and prompt branches were also exercised by the preceding relevant scopes. Prior/copy-seeded profiles were moved aside before coverage. All seven changed production Swift files are instrumented. Tests, string resources and nonexecutable lines are excluded from the diff/LCOV intersection. Project-wide coverage from a focused scope is a different measure.

Strict SwiftLint with the repository baseline passes for `AskTranslationFanout.swift`, `AskTranslationStackView.swift`, `AskWordCardView.swift` and `AskTranslationPanelView.swift` with zero violations. The three other touched Swift files retain 22 existing lint findings (including the shared plugin view's pre-existing length/complexity issues); comparison with the exact main versions confirms **zero new findings**. `git diff --check` and required localization-key uniqueness checks pass.

## Self-review

Reviewed the complete copy and recovery paths, per-service persistence and lookup defaults, zero / short / oversized example lists, new-card reset, pronunciation language routing, stale async results and session resets, injected settings, credential-safe failures, and updated localization / documentation. Found and fixed the old two-example generation and parsing limits so the third example reaches the view. Stack word cards share the outer result scroll rather than introducing a nested scroll area. The final visual review removed the stack-only example heading, clarified the whole-card copy label, retained the short missing/invalid-key messages and explicit Configure action, and supplied the launcher snapshot with its word-book dependency so all four card actions appear. Native sizing, scrolling and keyboard regressions remain passing. Live provider calls, real external-app paste and live OCR were not exercised by P3; capture/translation dependencies are injected fixtures.

## Design comparisons

Each figure includes both appearances, with design left and native window right:

- [Input translation](panel-comparison.png)
- [Word lookup](word-comparison.png)
- [Per-service failures](error-comparison.png)
- [Screenshot translation](shot-comparison.png)
- [Launcher fy](launcher-comparison.png)
- [Complete settings pane](settings-comparison.png)

Raw native captures are in [native/](native/); design crops in [design/](design/), with [capture dimensions](capture-dimensions.json). Native pixels are retained unchanged. Design crops were rendered at 2× and reduced to logical points for the comparisons. The screen's real height limit explains how many provider rows fit in the native panel; the design uses a simulated desktop. The full settings capture shows the entire pane, including all providers; app-level navigation and launcher chrome use the existing application components.
