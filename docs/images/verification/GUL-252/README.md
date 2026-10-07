# Launcher light palette review

The comparisons show the production `AskLauncherView` on macOS 26.6.2 with synthetic content: the left column is `a629a360` (main), the right column the GUL-252 changes. The demo state is screenshot on, memory off, standard permission mode and cloud storage, so the footer shows one switch in each state next to the permission menu.

- [Light comparison](light-comparison.png)
- [Dark comparison](dark-comparison.png)

The two glass rows are on-screen captures (`screencapture` of a test-owned backdrop window with the launcher panel above it), so they include the window server's Liquid Glass sampling of the backdrop. The last row is a bitmap of the opaque Reduce Transparency fallback. No account data or user desktop content is captured. These images do not establish appearance on macOS 13–15, where the popover blur replaces Liquid Glass.

To render them again, set `TYPEFLUX_LAUNCHER_PALETTE_SNAPSHOTS` to an output directory and run `swift test --filter AskLauncherPaletteRenderTests`. The test briefly shows two windows at the top-left of the main screen and closes them.

Verification on macOS 26.6.2:

- Full suite, `swift test --no-parallel --enable-code-coverage`: Swift Testing ran 1,700 tests. Excluding tests that read fixtures from `docs/` (absent from that mirror, all pass with it present), the remaining failures were `AskSurfaceOpacityTests.opaqueLauncherUsesWhiteInLightAndDeepGreyInDark`, updated here for the cool off-white surface, and four tests that fail the same way on the unmodified base `a629a360`: three in `AskSourceContextViewTests` and `AskComposerInteractionTests.voiceButtonClickAndHoldWorkInBothComposers`.
- Focused regression after rebasing onto `e82fa34b`: 205 Swift Testing tests in 31 suites and 4 XCTest tests (1 optional snapshot test skipped) passed:

```sh
swift test --no-parallel --enable-code-coverage --filter 'AskLauncherPaletteRenderTests|AskLauncherLightPaletteTests|AskGlassTests|AskWorkspaceGlassTests|AskFloatingPanelStyleTests|AskSurfaceOpacityTests|AskPermissionMode|AskContextChipsTests|AskLauncherHomeTests|AskMemoryChipClickTests|AskComposerChromeTests|AskLauncherHeaderTests|ClipboardPanelRenderingTests|AskWordBook|AskComposerResponsiveTests|AskHarnessVisualTests|AskCommandVisualTests|AskQuickResultsVisualTests'
```

- LLVM coverage of that run covers 113 of 119 changed executable production lines (94.96%). The uncovered lines build the permission menu's items, which SwiftUI evaluates only when the menu opens, and its selection callback.
- Strict SwiftLint with the repository baseline reports no new findings in the changed production files; the extraction removes three findings from `AskComposerViews.swift`.
