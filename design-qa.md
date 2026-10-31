# Model configuration visual QA

Source truth: GUL-126 attachments `model-v2-01-settings.png`, `model-v2-02-provider-models.png`, and `model-v2-03-picking.png`.

Implementation: production SwiftUI views, captured by `AskConversationVisualTests.renderModelSelectionSurfaces`. This is a native macOS application; browser and CSS checks do not apply.

## GUL-142 visual alignment (supersedes the scoped canvas below)

The model page no longer uses its own palette. `ModelVisualStyle` now maps to `StudioTheme` tokens, and the page sits on the same shell surface, top inset and header spacing as History and the other settings pages.

- Cards match `StudioCard`: 14-point continuous corners, thin `StudioTheme.border` stroke, `cardSurface` fill.
- Providers form grouped lists ("Connected" / "Not configured") with inset separators. Status is a dot plus label; unconfigured rows are dimmed instead of dashed.
- Scene selectors look like native pop-up buttons (provider logo, up/down indicator). The domain switch is a native segmented control.
- Provider details use label/field form rows. Test and Save sit in the card footer, and Save is enabled only after an edit. The API key can be revealed on demand.
- Model rows show accent scene badges. The `···` menu can assign a model to Rewrite or the Ask default, restricted to models the scene pickers would offer.
- Presentation rules (search, grouping, endpoint labels, dirty state, usage badges) live in `ModelSettingsPresentation` and are covered by `ModelSettingsPresentationTests`.

## Findings and fixes (GUL-126)

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


## Reminder permission screen — selected centered design (2026-10-31)

Source visual truth: `docs/evidence/apple-productivity-search/minimal-permission/reference.png` (the first displayed concept selected by the user).
Implementation: `docs/evidence/apple-productivity-search/minimal-permission/implementation.png`.
Full comparison: `docs/evidence/apple-productivity-search/minimal-permission/comparison.png`.
Focused comparison: `docs/evidence/apple-productivity-search/minimal-permission/comparison-focus.png`.

The native launcher is 750 × 600 points, captured at 1500 × 1200 pixels. The selected mock is 1402 × 1122 pixels. Both are normalized to 750 × 600 for comparison; embedded image profiles are converted to sRGB for comparison boards. The original native capture is retained without re-encoding. State: simplified Chinese, dark appearance, permission required, foreground controls. These are native window-backed fixture renders, not photographs of the installed menu-bar app.

### Findings and comparison history

- Initial P2: the native icon was smaller than the selected concept and the heading-to-icon rhythm drifted. Enlarged the native icon frame to 80 points and adjusted the vertical spacing and optical centering.
- Initial P2: native button padding made the action 40 points tall while measurement reserved 36. Reduced label height so the native button is 36 points and the actual fitting size agrees with the measured layout.
- Initial P2: the first native heading and body were narrower than the chosen concept. Normalized text-region comparison measured heading widths of 123 versus 145 points and body widths of 233 versus 256 points. Updated the native system typography to 26-point semibold, 15.5-point body and a 15-point semibold button, then re-captured and compared both full and focused views.
- Final comparison: centered composition, icon, short copy, one primary action, and vertical rhythm now match the selected concept without actionable P0/P1/P2 differences.

Required fidelity surfaces:

- Fonts/typography: system SF/PingFang; heading, body and action proportions checked at equal density; Chinese copy matches verbatim. Five localizations render without clipping in both appearances, for required and denied access.
- Spacing/layout: no inset permission card, redundant section heading, repeated footer action or privacy paragraph; centered in the expanded viewport. Icon, title, supporting line and native action gaps checked in both comparison crops.
- Colors/tokens: existing native dark surface and product blue retained. The keyword chip retains the application's existing blue text and the canvas uses its existing flat material instead of the generated mock's texture; these are intentional product-token constraints.
- Image/asset fidelity: the existing native Reminders icon is used at high interpolation quality. No synthetic illustration, emoji, rasterized UI or custom asset substitute is used.
- Copy/content: `查看提醒事项`, `允许 Typeflux 访问，即可搜索和查看。`, `允许访问`. The input uses `提醒事项` / `搜索提醒事项` while authorization is needed; normal search scope hints return afterward.

Interactions: the real native button is clicked through its accessibility frame in the actual launcher view; its center, target size, short placeholder and absent feature footer are asserted. Listing, scope change, preview, native-open routing, reopening and no AI submission remain covered by the same scenario. The foreground screenshot option preserves the original test host for unrelated cases.

Six legacy launcher methods still fail with the same 13 issues when the shared composer, results renderer and reading layout are restored to their pre-change HEAD versions. This control isolates those broader failures from the permission presentation; it is not a claim that every source file was reset to a full clean baseline. They concern sign-in recovery, notes, numbered/prefix keyword entry and workflow actions/images, and remain outside this permission-layout change. Complete installed-launcher computer-control acceptance is still unavailable for its menu-bar window.

Implementation checklist: selected visual mapped; native layout and localized copy implemented; input/footer simplified only during permission setup; twenty locale/appearance/access-state renders checked; physical button flow passed; source and rendered implementation compared together.

final result: passed
