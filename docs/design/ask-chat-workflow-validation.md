# Chat workflow authoring validation

Validated locally on macOS with Xcode's Swift toolchain on 2026-10-08.

- `swift build`: passed.
- `swift test --no-parallel --enable-code-coverage --filter AskWorkflowAuthoring`: 15 new tests passed. The opt-in native rendering test also ran with `TYPEFLUX_ASK_SNAPSHOTS` set, producing wide light/dark and narrow screenshots.
- New authoring core line coverage: **97.67%** (335 / 343 lines), measured across `AskWorkflowAuthoringSession`, `AskWorkflowAuthoringStore`, and `AskLocalTools+WorkflowAuthoring`. Region coverage: 94.58%; function coverage: 91.30%. This is scoped core coverage, not whole-app or UI coverage.
- `make coverage` on the feature branch based on `54474abb`: ran 3,035 XCTest tests (7 skipped, no failures) and 1,728 Swift Testing tests. The latter reported six assertions in four existing UI tests. The command therefore exited unsuccessfully; it is not a green full-suite result. Core coverage was extracted from the completed run's raw profiles.
- After rebasing onto `fee46308` (the translation-services update), `swift test --no-parallel --enable-code-coverage --filter 'AskWorkflow|AskConversation|AskLocalTools|AskWorkspaceLayout|AskResponsiveWorkspace|AskTranslation|Localization'` passed all **470** selected tests (51 XCTest + 419 Swift Testing). Localization conflicts were resolved by preserving both features' keys.

## Baseline failures

An isolated, unmodified worktree at `54474abb` was built with the same dependency lockfile. Running `swift test --no-parallel --filter AskComposerInteractionTests` reproduced the same six assertions in its 28-test suite:

| Existing test | Assertion |
| --- | --- |
| `voiceButtonClickAndHoldWorkInBothComposers` | Voice button frame differs from its resting frame. |
| `sourceChipPreviewsMetadataAndRemovalCanBeUndoneWithoutAScreenshot` | Two source-label visibility/OCR assertions fail. |
| `narrowLauncherWrapsContentAndKeepsMemoryInTheFooter` | Safari label is not found in either language case. |
| `selectedTextPreviewCanRemoveOnlyTheSelection` | Selection label frame is not found. |

The initial parallel full run also exhibited unrelated focus/localization races. The coverage script now passes `--no-parallel`, because AppKit tests share window focus and the localization singleton. This removes those cross-suite races but does not fix the six baseline assertions above.

## Scope of verification

Tests run real local scripts through the workflow runner, including generated image output, cancellation, and timeout. A scripted Chat API verifies the tool-call/approval/receipt loop without requiring a paid model or credentials. Natural-language skill selection by a live model was not exercised. Screenshots use the production SwiftUI views with deterministic sample conversation data.
