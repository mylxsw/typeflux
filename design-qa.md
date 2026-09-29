# Model configuration visual QA

Source truth: GUL-126 attachments `model-v2-01-settings.png`, `model-v2-02-provider-models.png`, and `model-v2-03-picking.png`.

Implementation: production SwiftUI views, captured by `AskConversationVisualTests.renderModelSelectionSurfaces`. This is a native macOS application; browser and CSS checks do not apply.

## Findings and fixes

| Severity | Earlier evidence | Fix and final evidence |
| --- | --- | --- |
| P1 | Scene card had a stacked header, excess height and unbounded text-only selections. | One compact header, three separated 64-point rows, consistent 240×32 selectors. `docs/images/models-settings-dark.png`. |
| P1 | Light provider cards showed multiple soft shadow bands; fields and actions looked like small default controls. | Flat bordered surfaces, 34-point fields, 32-point buttons, visible primary catalog action. `docs/images/models-provider-light.png`. |
| P1 | Provider screenshot omitted the surrounding app; production detail retained the generic Models heading above its own heading. | Shared navigation state displays the provider heading and back action once, inside the real settings shell. Both full-window provider captures. |
| P2 | Model rows had loose spacing, inset separators and unstyled purpose labels. | 44-point rows, full-width separators, muted capsule labels and a compact overflow action. `docs/images/comparison-provider.png`. |
| P2 | Selection used a system menu without the reference's grouped rows and selected background. | Shared production popover with grouped models, explicit checkmark, blue selected background and separate default action. `docs/images/models-menu-dark.png`. |
| P2 | Loaded models were difficult to distinguish; selected existing entries appeared disabled. | Dedicated catalog component, clear checked entries, separate non-chat reason, model search and accurate newly-selected count. `docs/images/models-catalog-dark.png`. |
| P2 | Dark page was too light, tabs were oversized and page top spacing drifted. | Scoped model-page canvas, 36-point tabs, 32-point content top inset. Other settings sections retain their theme. Speech and language captures. |

## Comparison history

1. Opened all three original design boards and the previous delivery screenshots. Recorded the P1/P2 differences above before editing.
2. Rendered both appearances after the layout/surface changes. Fixed the remaining tab height, provider heading, catalog checked-state contrast and menu height.
3. Re-rendered the final production components and compared the source and implementation together in the four comparison images. No unresolved P0/P1/P2 visual findings in these captured states.

## Capture and normalization

- Original boards: 3720×1980, 3480×1600, and 3120×1120 pixels. The boards contain several screens, captions and surrounding presentation canvas.
- App captures: 1200×880 points/pixels, scale 1, light and dark, for both tabs and the full provider detail. Catalog: 580×470. Model chooser: 360×370.
- Comparison images crop the app-owned content from the boards, excluding presentation titles and sidebar chrome, and scale both content regions to the same 800-pixel width. Board crop coordinates are converted from their 2048-pixel inspection width to original pixels before cropping.
- Full-view evidence: `docs/images/comparison-speech.png` and `docs/images/comparison-provider.png`.
- Focused evidence: `docs/images/comparison-catalog.png` and `docs/images/comparison-menu.png`.
- State: Chinese locale, synthetic provider credentials/model metadata. The app is logged out, so cloud availability and the number of configured speech providers intentionally differ from the logged-in design board. The chooser uses the logged-in presentation input to display configured cloud choices. Layout comparisons do not treat these data differences as spacing defects.

## Required fidelity surfaces

- Typography: system SF/PingFang with a 23-point page title, 13–15-point primary UI text, 11–12-point secondary text and monospaced model IDs. Checked for truncation in the captured settings/detail/catalog/chooser states.
- Spacing: compact scene header, aligned control edges, 58-point provider rows, 44-point model rows, 12-point card corners; no heavy decorative shadows.
- Colors: flat dark canvas, separated card/input surfaces, restrained borders, green availability dots, blue primary/selected states; light appearance uses the same hierarchy.
- Assets: existing Typeflux branding and native SF Symbols remain sharp. The mock's generic letter badges are represented with native provider/category symbols; no new raster illustration is required.
- Copy: Ask default remains explicit; current-conversation selection and setting the default remain separate actions. Availability reasons and non-chat explanations remain visible.

## Intentional differences and remaining limits

- Preserve the existing app sidebar, logo, account card and current provider order. These are shared application components, not new mock artwork.
- Keep an explicit Save button for edited connection data and fully mask credentials. The design's partially visible key is not reproduced.
- The catalog Add count measures new selections, so the initial count is zero when only existing models are checked; the mock's initial “3” would misleadingly suggest adding duplicates.
- Retain supplied model names and unavailable states instead of inventing catalog names or credentials to match the mock.
- Source boards provide dark designs; light appearance is an adaptation using the same geometry and hierarchy.
- Native popover chrome, text antialiasing and the shared sidebar are not claimed to match every source pixel. Long catalogs scroll. Captures do not replace live-provider or full keyboard/VoiceOver end-to-end testing.

## Validation

- `swift build`.
- `TYPEFLUX_ASK_SNAPSHOTS=<directory> swift test --filter 'AskConversationVisualTests.renderModelSelectionSurfaces|AskModelSelectionTests|ModelRegistryTests|StudioViewModel'`: model/scene regressions plus production render coverage.
- Strict SwiftLint on the five changed visual component files; `git diff --check`.

final result: passed
