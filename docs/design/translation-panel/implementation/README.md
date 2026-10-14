# Concurrent launcher translations (GUL-387)

The launcher `fy` now previews local translations and saved word cards while typing. Return submits the ordered, enabled services concurrently; each result completes or fails independently. The first AI service writes word cards, additional AI services translate briefly, and saved cards bypass every AI service until explicit regeneration.

The service list persists as v2, migrates every v1 engine/on-device/fallback combination while retaining v1, supports multiple models and drag ordering, and reuses the provider credential sheet. Keys remain in Keychain. The launcher and the future translation panel share `AskTranslationStackView`.

## Native comparisons

Each image shows dark above light, with the design on the left and a native Mac window capture on the right. Word uses the design's `launcher` scene; sentence and failure use its shared `panel` / `error` result stack. Settings compares the service-list region. Design screenshots render the unchanged interactive HTML. Native captures use AppKit/SwiftUI launcher windows and isolated deterministic engine/credential fixtures, recorded with macOS `screencapture`; they are not HTML mockups.

- [Word](word-comparison.png)
- [Sentence](sentence-comparison.png)
- [Per-service failure](error-comparison.png)
- [Ordered services](settings-comparison.png)

The existing launcher chrome and word-card content component are retained. Enabled demo providers differ from production defaults. The native settings fixture also shows a removed AI model. The existing on-device engine requires macOS 26 APIs; this change does not extend platform support. Its status says “installed languages” rather than repeating the design's macOS 15+ demo claim.

## Focused validation

Validation ran on the connected Mac with Xcode 27 / Swift 6.3.1. `swift build --jobs 4` passed (235.49 seconds including build startup).

The coverage scope covers migration and settings, per-model DI and LLM routing, provider clients and streaming, TaskGroup cancellation/stale-result isolation, privacy, word-book/card behavior, and directly affected plugin/session/native keyboard interactions. After merging current main, the directly affected primary-action and workflow-keyword suites were added to cover its updated Return/header routing. No full-inventory test run was used.

Actual final command:

```sh
make coverage \
  SUITE="AskTranslationSettingsTests AskTranslationLLMServiceTests AskTranslationSettingsModelTests AskTranslationProviderSheetTests AskKeywordDraftServiceTests AskTranslationRoutingTests AskTranslationFanoutTests AskTranslationStackViewTests AskTranslationEngineFactoryTests AskTranslatePluginTests AskTranslationEngineTests AskTranslationLanguagesTests AskTranslationServiceTests AskTranslationTextChunkerTests AskPluginSessionTests AskPluginViewTests AskWordCardTests AskWordCardViewTests AskWordLookupEngineTests AskTranslatePluginWordCardTests AskTranslatePluginGarbledCardTests AskWordCardTranslationTests AskWordCardTranslationViewTests AskTranslateWordBookTests AskTranslateRecentWordsTests AskPluginSessionWordBookTests AskWordBookDictTests AskWordBookOpenTests AskLocalizationPolishTests TypefluxCloudFeatureTests AskLauncherPrimaryActionTests AskWorkflowKeywordSelectionTests" \
  FILTER="AskQuickResultsInteractionTests/(translationStack.*|aKeywordBecomesAChipAndTypedTextTranslatesWhileTyping|withNothingTypedTheSelectionIsTranslatedOnReturnAndWrittenBack|tabChangesTheLanguageAndCommandRAsksTheAI|backspaceTurnsTheChipBackIntoText|aLoneKeywordEntersThePrioritizedFeatureOnReturn|headerConfirmsThePluginAndCommandReturnTakesTheResultToAI|escapeCancelsARunThenLeavesTheKeywordThenCloses|modelActionsSpeakCompareFoldAndRecoverFromFailedWriteBack|anAIPromptStreamsOnReturnThenCopiesAndRegenerates|commandSStarsTheWordAndUsingTheResultKeepsIt)"
```

The installed Swift build backend did not emit profiles through the runner's coverage discovery step. After trying the normal runner first, the same scope ran with a temporary Swift wrapper selecting `--build-system native` and adding `-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping` to coverage commands. `LLVM_PROFILE_FILE` pointed at the native build's `codecov` directory. The wrapper is an environment workaround, not a repository change.

The integrated scope ran 191 Swift Testing methods across 32 suites plus four XCTest feature tests (369.275 seconds including rebuild/discovery). One existing workflow Tab/Return fixture timed out in the combined native run; it passed unchanged in an isolated method retry (78.667 seconds). All other selected methods passed in the combined run. Profiles from the integrated scope and the targeted retry were merged with `llvm-profdata merge`; no passing-results cache was used.

Changed-code coverage: **94.19% (1134/1204 executable changed lines)**. The final footer-only capture rerun kept the translation shortcuts visible after the new main header added auxiliary hints: one screenshot method passed (63.929 seconds).

Changed-code coverage is executable added/modified production Swift lines against merged main (`5f4fddea`) from `git diff origin/main --unified=0`, intersected with `llvm-cov export -format=lcov` line records. Tests and localization resources are excluded from the denominator. [Per-file measurements](changed-code-coverage.json) include uncovered lines; the project-wide number from this focused run is not the changed-code metric.

Strict SwiftLint passed for all four new production files (zero violations). Repository-wide lint reported 1,722 large-file/style violations and is not claimed as passing. `git diff --check` passed.

Earlier validation caught and fixed dictionary-only injection, recent-word-book shortcut preservation, original whitespace preservation, and configuration-sheet accessibility. Their failed methods/smallest suites were retried; a 16-test retry passed (83.234 seconds), but profile export initially failed. Runner/build retries took 134.127, 112.727, and 211.617 seconds; the first executed focused pass took 73.237 seconds. Explicitly instrumented coverage subsequently passed in 244.720 seconds. A screenshot-only retry increased settings capture height to include the full footnote and passed (64.578 seconds). A new incomplete-card fixture initially queried an inaccessible disabled control; the corrected native keyboard assertion passed in its one-method retry (70.626 seconds), after a 119.027-second validation pass. The service-settings refresh passed seven focused tests (90.308 seconds).

## Self-review

Reviewed entry-to-result flow, empty and corrupt settings, duplicate IDs, removed models, empty/garbled replies, service failures, cancellation and generation isolation, session reuse, partial-result selection, privacy authorization, credential handling, localization, and existing word-book behavior.

Fixed queued Return authorization surviving input edits, partial selection changing at final completion, cached-card regeneration retaining the cached marker, retries rerunning siblings, and insertion controls accepting cards without target-language meanings. Native regression tests cover partial Return/Command-number copying, selected insertion, Tab's privacy behavior, provider-sheet save and isolated retry, card regeneration/star/copy/book shortcuts, and disabled insertion of incomplete cards. Credential editing refreshes service settings first so removing keys cannot overwrite another window’s newly saved AI models/order.

External provider credentials, quotas and installed language packages are not exercised against live services; provider client tests and injected native fixtures cover their routing and failure UI.
