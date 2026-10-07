# Floating panel style review

The comparisons render the production SwiftUI views on macOS 26.6.2 with synthetic content. The left column uses commit `2d0a58b7`; the right column uses the GUL-244 changes. No account data or user desktop content is captured.

- [Light comparison](light-comparison.png)
- [Dark comparison](dark-comparison.png)

Bitmap captures show layout, text, selection colours and the SwiftUI frost layer. They omit the window server's desktop sampling and Liquid Glass refraction. The fallback and opaque material paths are exercised on the current OS; these images do not establish appearance on older macOS versions.

To render the changed panels again, set `TYPEFLUX_PANEL_STYLE_SNAPSHOTS` to an output directory and run `swift test --filter AskFloatingPanelStyleTests`. Set `TYPEFLUX_ASK_GLASS_SNAPSHOTS` and run `swift test --filter AskLauncherGlassVisualTests` for the launcher material matrix. Tests close their temporary windows and use local fixtures.

Full verification with `swift test --no-parallel --enable-code-coverage` ran 3,015 XCTest tests (7 skipped, no failures) and 1,632 Swift Testing tests (10 failed assertions). All 10 assertions also reproduced on the unmodified base in focused runs: source/selection display, the recording button frame, unknown execution recovery, and workflow output popovers. Full-suite acceptance remains blocked by those baseline failures.

LLVM coverage from that full run covered 80 of 81 changed executable production lines (98.77%). This is coverage of the change, not a claim that the full test suite passed. The new native rendering test file passes strict SwiftLint; changed production files retain the same 49 strict lint findings as the base.

The final focused regression run passed 78 Swift Testing tests and 8 XCTest tests (1 optional snapshot test skipped), with no failures:

```sh
swift test --no-parallel --enable-code-coverage --filter 'AskFloatingPanelStyleTests|AskWorkspaceGlassTests|AskGlassTests|AskSurfaceOpacityTests|AskPluginListViewTests|AskPluginViewTests|AskWordBookDictTests|AskTranslateRecentWordsTests|AskWordBookOpenTests|ClipboardPanelRenderingTests|ClipboardPanelKeyCommandTests|AskWorkflowItemRowTests|AskWorkflowItemListTests|AskPluginOutputItemTests'
```
