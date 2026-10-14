# GUL-388 P2 review fixes

The three requested review fixes are implemented on main at `73aa1f6f`. PR #490 had already merged when its state was checked (2026-10-14 14:08:25 UTC), so these changes are delivered in a follow-up PR for the same issue.

- Selection translation always captures the current selection and translates once. A visible pinned panel keeps its top-left position and pin state; an unpinned panel moves beside the new selection. An empty selection only focuses an existing panel, preserving its text, results and source context.
- Native SwiftUI preferences measure the title, original, language bar, result document, notice and footer. The panel fits their actual heights and caps at the configured screen fraction, with overflow scrolling inside the results.
- All three shortcut rows show localized gray descriptions. Rows grow for wrapped descriptions instead of using a fixed height.

## Native before/after evidence

Each figure contains dark appearance above light appearance:

- [Pinned panel: before and after invoking selection translation again](pinned-selection-before-after.png). Both captures are from the fixed build and show the same pinned window switching from the old passage to the new one. Assertions verify a fresh explicit capture, one additional translation call, unchanged pin state and unchanged top-left screen coordinates.
- [Sentence panel height](panel-height-before-after.png): 452×433 → **452×405**.
- [Screenshot panel height](screenshot-height-before-after.png): 452×465 → **452×435**.
- [Shortcut descriptions](settings-before-after.png).

Height/settings baseline captures come from the reviewed `91943325` build. Raw images are retained under [before/](before/) and [after/](after/), with [dimensions](capture-dimensions.json). Panel captures keep their original scale; the settings comparison scales both sides equally. The captures use real AppKit windows on the configured Mac mini with deterministic injected translation/selection/OCR fixtures. Live providers and external-app paste were not exercised.

## Focused validation

The first scope covers coordinator entry/cancellation and screenshot dependencies, new selection regressions, native sizing/scrolling/keyboard, subtitle rendering, existing session/policy behavior and the shared stack in the launcher:

```bash
make coverage \
  SUITE="AskTranslationPanelCoordinatorTests AskTranslationPanelSelectionTests AskTranslationPanelControllerTests AskTranslationPanelSettingsViewTests AskTranslationPanelModelTests AskTranslationPanelPolicyTests AskTranslationStackViewTests AskScreenshotFollowUpTests" \
  FILTER="AskQuickResultsInteractionTests/translationStack.*"

# Smallest containing suite for the failed height assertion
make coverage SUITE="AskTranslationPanelControllerTests"
```

The existing runner used the previously verified temporary native Swift wrapper: `--build-system native`, `-Xswiftc -profile-generate` and `-Xswiftc -profile-coverage-mapping`. Repository runner scripts were not modified. UI suites use `.exclusiveUIState`.

| Command | Total command wall time | Result |
| --- | ---: | --- |
| First focused coverage pass, including rebuild/discovery | 203.53 s | 65/66 methods passed |
| Controller suite retry, including test rebuild | 95.44 s | All 5 methods passed |
| SwiftFormat + strict SwiftLint with repository baseline | 0.70 s | Zero violations in all 6 changed production Swift files |
| `git diff --check` | — | Passed |

The one failure was in the new height test's lookup of a footer Accessibility identifier. The test now checks the visible last result against the native window bottom edge, allowing only the 28-point footer and ordinary spacing, and verifies that four rows add 40–90 points compared with three. Production code did not change before the targeted retry. All **66 unique selected methods in 9 suites pass after that retry**. No full suite was run.

[Changed production-code coverage](changed-code-coverage.json): **98.53% — 67/68 executable added or modified Swift lines**, against `origin/main` at `73aa1f6f`. Only this review run's profiles are used. All six changed production Swift files are instrumented. The sole uncovered line is the view's unused default height callback. Profile merging reported a counter mismatch only for the edited test method; no production function changed between the two passes. Tests are excluded from the LCOV/diff intersection. This figure is separate from project-wide coverage and the earlier P2 measurement.

## Self-review

The entry-to-result path, empty selections, stale captures, pinning and placement, resource cancellation, explicit provider authorization, view measurement updates, max-height scrolling, localization and settings rendering were reviewed. Selection probing uses its own cancellable task so that an empty selection cannot cancel pending screenshot OCR. New captures replace the source application's selection context only when valid, and dismissal/new entries still invalidate pending captures. Height updates ignore nonfinite/unchanged values, schedule resizing after layout and preserve the panel's top-left anchor. No credentials or new external calls were added.
