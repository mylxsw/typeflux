# P1 review fixes

Word lookups now assign the card to the first checked AI service. Cached word-book cards appear in that service's row without calling an AI. With no AI checked, enabled device/provider services return brief translations without a card. The word-book model and `translationLLMConfiguration` follow the checked AI, falling back to the first AI entry when none is checked. That first entry remains protected from deletion regardless of its checkbox. Explicit AI keyword overrides and regeneration follow the checked service, preserving the existing explicit fallback when none is checked.

AI rows show a light localized Model label. Unchecked names and status indicators use 55% opacity. Removed-model picker text is shortened to “Pick again” / “重新选择”; the row title retains the unavailable-model explanation. The footer describes the first checked AI.

PR #483 was already merged before these fixes were delivered. The fixes remain on its original branch and are delivered in a follow-up PR against main.

## Native before/after evidence

The left side is production revision `819006cf`; the right side is the review fix. Dark is above light. Both sides use the same isolated AppKit/SwiftUI fixtures and native macOS `screencapture`, with injected deterministic engines and credentials. The baseline ran only the new snapshot fixtures against unchanged production code. Images are resized for comparison without changing their contents; original PNGs are included in the issue attachment.

- [First AI unchecked, second AI checked](unchecked-first-before-after.png): the old build produces brief rows without a card; the fix pins the second AI's word card above the other services.
- [Settings list](settings-before-after.png): Model labels, short removed-model text and dimmed unchecked rows.
- [Settings with first AI unchecked](settings-unchecked-before-after.png): the card role moves to the second AI while deletion protection stays on the first entry.

Settings fixtures also capture English and Simplified Chinese in both appearances. The removed model intentionally remains a visible configured reference; the enabled removed-model row demonstrates ownership status independently of model availability.

## Focused validation

Connected Mac, Xcode 27 / Swift 6.3.1. Routing/Fanout tests cover checked ownership, cached-card placement, no checked AI, explicit keyword overrides, regeneration, privacy and cancellation. Settings/model/engine tests cover structural deletion protection, model fallback and removed-model options. Word-book/card suites cover the directly affected persistence/output callers. Native interaction and rendering tests cover the launcher and localized settings.

Baseline screenshot capture:

```sh
make coverage FILTER="(AskQuickResultsInteractionTests/translationStackLauncherSnapshots|AskTranslationStackViewTests/rendersEveryResultStateAndSettingsInBothAppearances)"
```

Two tests in two suites passed; total command wall time **75.736 seconds**. This was the requested before/after comparison, not a production validation pass.

Final validation and after captures:

```sh
make coverage \
  SUITE="AskTranslationFanoutTests AskTranslationRoutingTests AskTranslationSettingsTests AskTranslationSettingsModelTests AskTranslationStackViewTests AskTranslationLLMServiceTests AskTranslationEngineFactoryTests AskTranslateWordBookTests AskTranslatePluginWordCardTests AskTranslatePluginGarbledCardTests AskLocalizationPolishTests" \
  FILTER="AskQuickResultsInteractionTests/translationStack.*"
```

**72 tests in 12 suites passed; total command wall time 92.231 seconds**, including a 53.62-second rebuild and 22.632 seconds of test execution. The first attempt failed to compile a new test because its concrete SQLite store required an explicit `at:` argument (67.937 seconds). Adding the timestamp fixed it; the same focused command was retried, as required for a build failure. No selected tests failed during execution. No full-inventory or duplicate plain-test run was used.

Coverage uses the existing temporary native SwiftPM instrumentation wrapper described in the parent implementation report. Review-fix changed-code coverage is **100% (21/21 executable added/modified production Swift lines)** against `819006cf`, from this focused run's profile alone. Resources and test code are excluded. [Per-file coverage](changed-code-coverage.json) lists the denominator and uncovered lines; this is not project-wide coverage. All touched production/test files are unchanged between the tested revision and current main except these fixes. `git diff --check` passed.

## Self-review

Reviewed fresh and cached lookups, preview authorization, checked/unchecked transitions, no-AI behavior, row pinning, keyword overrides, targeted regeneration, protected deletion, word-book model fallback, missing models, localization and both appearances. The review caught that cached-card injection could still synthesize a disabled AI row; both plugin cache lookup and Fanout now require a checked card owner. Regression tests cover that path. Cancellation, task cleanup and stale-result guards are retained, and the changes add no credential access or remote-error exposure. Native captures confirm the deleted-model picker is readable and first-entry deletion protection remains visible in both checkbox states.

External providers use injected fixtures; no live credential/quota requests were made.
