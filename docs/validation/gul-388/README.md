# GUL-388 translation panel validation

The translation panel adds explicit input, selected-text and screenshot entry points while sharing the launcher's translation stack. It supports pinning, safe insertion, local history, retention, placement and height preferences, automatic copying, and the documented keyboard commands. Launcher Command-P transfers current results and ongoing work without starting another provider request. English and Simplified Chinese strings are included.

This branch preserves the P1 review fixes from PR #486 and incorporates main at `c9724857`. Until #486 merges, those fixes also appear in the PR against main.

## Design and native macOS captures

Each comparison puts the design on the left and the real AppKit/SwiftUI window on the right, with dark appearance above light appearance:

- [Sentence panel](panel-comparison.png)
- [Word card](word-comparison.png)
- [Provider failure](error-comparison.png)
- [Screenshot translation](shot-comparison.png)
- [Shortcut and panel settings](settings-comparison.png)

Original native captures are in [native/](native/). They were taken on the Mac mini with macOS 26.6.2, Xcode 27 and Swift 6.3.1 using native window capture. The fixtures supply deterministic translation, OCR and injection responses; the windows, editing, keyboard events, sizing, scrolling and appearances are real. No production account or translation API was called.

The design and native fixtures use different example text and provider counts. The screenshot fixture includes a real image thumbnail and two recognized lines. The native settings retain the confirmed unset shortcut defaults; the design's populated shortcuts and extra enabled providers are demonstrations. Native word-card content and typography reuse the P1 stack.

## Focused checks

Coverage replaced a separate plain test run. The selected scope covers panel behavior and policies, entry routing and OCR, actual window/keyboard/scroll interactions, settings compatibility, shared translation routing/fanout/engine/stack behavior, launcher handoff, screenshot follow-up, and hotkey/selection dependencies:

```bash
make coverage \
  SUITE="AskTranslationPanelModelTests AskTranslationPanelPolicyTests AskTranslationPanelCoordinatorTests AskTranslationPanelControllerTests AskTranslationPanelSettingsViewTests AskTranslationSettingsTests AskTranslationSettingsModelTests AskTranslationFanoutTests AskTranslationRoutingTests AskTranslationStackViewTests AskTranslationEngineFactoryTests AskTranslatePluginTests AskScreenshotFollowUpTests HotkeyConflictCheckerTests KeywordHotkeyTests TextSelectionSnapshotTests AskPluginSessionTests" \
  FILTER="AskQuickResultsInteractionTests/translationStack.*"

# Smallest containing suites after fixing the failing placement assertion
make coverage SUITE="AskTranslationPanelPolicyTests AskTranslationPanelControllerTests"
```

The normal runner was used first. For this Mac toolchain, coverage subsequently used a temporary Swift wrapper selecting `--build-system native` and adding `-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping` to coverage builds. The wrapper called the same `make coverage` scopes above; repository runner scripts were not changed. UI fixtures ran serially with `.exclusiveUIState`.

| Check | Total command wall time | Result |
| --- | ---: | --- |
| Native production build: `swift build --build-system native -j 4` | 122.64 s | Passed |
| First normal coverage build | 283.72 s | Compile failure in new test's nested `#require`; fixed before execution |
| First instrumented native rebuild | 255.66 s | Discovery blocked by archive metadata files; removed those task-created files |
| Focused coverage with verified discovery/build cache | 77.55 s | 22 XCTest methods passed; 105/106 Swift Testing methods passed |
| Policy/controller retry, including refreshed native captures | 84.31 s | All 8 methods passed |
| Strict SwiftLint on 12 affected production files | 4.07 s | Zero violations |
| `git diff --check` | — | Passed |

The one executed test failure was a placement assertion comparing CGFloat and Double expressions through `#expect`; it now compares a CGFloat difference with a 0.001 tolerance. Native capture was also ordered before bitmap cache capture to preserve the window backing contents. All **128 unique selected test methods pass after the targeted retry**. No full repository suite was run.

## Changed-code coverage

[Machine-readable coverage](changed-code-coverage.json): **91.68% — 1146/1250 executable added or modified production Swift lines** against `origin/main` at `c9724857`, including preserved P1 review changes.

LLVM profiles from this task's focused pass and targeted retry were merged. Coverage counts LCOV executable lines intersected with added/modified Swift lines from `git diff origin/main`; tests and documentation are excluded. Every changed production Swift file was instrumented. The retry changed only tests, so test-function profile mismatch warnings do not affect this production-only measurement. This is changed-code coverage, not project-wide coverage.

Uncovered paths include production AppCoordinator/DI assembly, some physical Accessibility selection geometry, and parts of screenshot forwarding/settings interactions. Safe external-app delivery and OCR outcomes are tested through injected implementations; actual provider credentials, external-app paste and physical region selection were not exercised.

## Self-review

The complete path was reviewed from hotkey registration and screenshot follow-up through entry capture, translation, history, copying/insertion and dismissal. Review fixed:

- Settings normalization and decoding preserve panel preferences and old v2 data.
- Selection state is cleared for new input/source entries; replacement checks the captured process and selection, with copy-and-notice fallback on failed or unconfirmed delivery.
- Stale OCR cannot overwrite edited input or reopen a dismissed panel; pin state survives recognition.
- Private launcher previews remain private after transfer and language swapping. Transferred work keeps its source fanout and model/engine choice; later launcher work uses a separate fanout.
- Selected-result keyboard movement scrolls within the panel. IME composition, input selection and caret boundaries retain normal editing behavior.
- Tasks, window event monitors, observers and temporary translation sheets have cancellation/removal paths.

No credentials were added. History stays in local defaults with bounded storage. No unrelated refactor or runner changes were included.
