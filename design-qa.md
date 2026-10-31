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

Installed follow-up: `f7338f73` is on main and pushed. A parallel Debug development installation already contained the approved UI; its executable UUID, newer build timestamp, six matching UI source files and short localized resources were reconciled before reuse. Deep/strict signing and preserved configuration/provisioning checks pass, and the installed main host is running. A stable copy of the parallel work was tested in isolation with both permission methods and all twenty renders passing; that copy was removed afterward. Total design-task test-command wall time: 874.89 seconds. Complete live menu-bar automation remains outside this native-fixture visual acceptance.

final result: passed

## Natural-language reminders — 2026-10-31

The strict format banner is replaced by AI interpretation on Return. Vague time wording produces a compact task/time proposal with an explicit creation action. The time is marked as suggested, uses primary contrast, and the extra explanatory footer is removed. The native Chinese fixture checks the actual launcher factory and Return route; creation is recorded in memory. Existing rows keep their default appearance. Evidence and validation: `docs/evidence/apple-productivity-search/natural-language-reminders.md`.

# Onboarding workbench — selected option 3

Source visual truth: `docs/evidence/onboarding-workbench/selected-design.png` (872 × 1804 pixels, three stacked frames).

Implementation: production SwiftUI views plus the installed `Typeflux Dev.app`, inspected through native computer use. The fixed window is 960 × 664 points. Live screenshots and hosted-view captures are 1920 × 1328 pixels at 2× density.

## Capture and comparison

Source frame crops: `(0, 0, 872, 596)`, `(0, 602, 872, 596)`, `(0, 1204, 872, 600)`. Each crop and implementation screenshot is normalized to 872 × 603 pixels. Comparison images place the selected design on the left and the implementation on the right. Source framing varies slightly between generated frames; normalization retains the application's 960:664 viewport.

- Full views: `docs/evidence/onboarding-workbench/comparison-services.png`, `comparison-cloud.png`, `comparison-speech.png`.
- Focused control and footer comparisons: `focused-connection.png`, `focused-footer.png` in the same directory.
- Final native acceptance: `native-services-zh.png`, `native-speech-zh.png`; the final Cloud page was also opened and visually reviewed.
- Controlled states: `services-zh.png`, `cloud-zh.png`, `speech-zh.png`, `speech-error-zh.png`, `services-en.png`, `finish-deferred-en.png`.

macOS traffic lights, the purple screen-sharing indicator and pointer highlights are system-owned and excluded from fidelity judgments. App icons use the supplied Typeflux artwork; other symbols use SF Symbols and the native menu bridge. Provider names retain the application's actual catalog copy.

## Findings and comparison history

All P0/P1/P2 findings below are resolved.

| Severity | Finding | Fix and verification |
| --- | --- | --- |
| P2 | The first pass undersized supporting text and compressed the rail's vertical rhythm. Same-size comparison and local OCR confirmed smaller subtitle/status bounds. | Increased display/body/control sizes, rail cadence and primary-action space. Compare `comparison-speech-before.png` with `comparison-speech.png`; reviewed final installed pages. |
| P2 | The shared speech selector rendered a short capsule instead of the inset field. | Reused `TFNativeMenuControl` inside a scoped 42-point rectangular field. Opened its real provider menu and canceled with Escape; selection was preserved. |
| P2 | Launcher-only copy implied configured features would become unavailable. | Copy now reflects existing speech/AI configuration. Native acceptance showed the existing-model message; empty fixtures show unavailable capabilities. |
| P2 | Deferred steps could appear completed. | Skipped stages use a minus indicator and localized accessibility value. Confirmed in the native permission/finish flow and controlled recovery screenshot. |
| P2 | Combined validation could clear a failed language result or navigate after leaving the task. | Preserved current failures; clear pending navigation on Back, Skip, editing and model changes. View-model regressions passed. |
| P2 | The English finish summary's intrinsic layout could move its title above the viewport. | Made the finish body scroll independently of the pinned footer, added a heading-bounds assertion, recaptured `finish-deferred-en.png`; all four affected UI methods passed. |

## Required fidelity surfaces

- **Typography:** native SF/PingFang, 36-point setup headings, 18-point supporting text, 15-point rail/actions and readable field/status labels. Hierarchy, Chinese/English wrapping and title bounds were inspected. Editable native text differs slightly from the generated reference's raster stroke/antialiasing.
- **Spacing/layout:** 208-point rail, 40-point content insets, stable footer and at least 28 points below its primary action. Selection groups, inset fields, substeps and content alignment follow the selected structure. Scrollable model/permission/finish bodies retain access to long content.
- **Colors:** scoped opaque graphite surfaces, restrained blue selected states/actions, neutral secondary text and amber unverified status. Light appearance uses the same geometry. Existing/native control state colors are retained.
- **Image quality/assets:** original Typeflux icon at native resolution; standard SF Symbols for cloud, account, speech, server and status. No placeholder art, screenshot-backed controls or recreated raster logos. The generated backdrop grain and exact generated icon strokes are intentionally represented by native materials/symbols.
- **Copy/content:** Cloud remains optional and account entitlement is explicit. Custom service order is speech → language model. Existing model connections survive skips. Missing capabilities and recovery actions remain explicit. All 66 statically referenced setup strings resolve in English, Simplified/Traditional Chinese, Japanese and Korean.
- **Interactions/accessibility:** one primary action per setup page; shared login/editor entry points, native provider menu, headings, selected rows, current/completed/skipped stage values, loading/failure states and keyboard default action. Primary control and finish heading bounds are checked. Full VoiceOver certification was not performed.

## Functional verification

67 unique relevant methods passed across the focused validation phases:

- `OnboardingViewModelTests`: 33; routing, prerequisites, verification, stale results, deferrals and recovery.
- `OnboardingBehaviorTests`: 13; native controls, rendering, editor/login entry points and fixed-window bounds.
- `OnboardingFeatureTests`: 7; guide and permission dependencies.
- `CloudLoginSyncCoordinatorTests`: 9; entitlement and existing-model handoff.
- Five selected `WorkflowControllerProcessingTests`: deferred/missing speech setup, account-free model recovery and missing-language-model guards.

The first preparation attempt failed on a local Swift macro-plugin lookup before any test executed (25.63 seconds). With the existing local compiler compatibility wrapper, the 67-method pass took 252.85 seconds; one new UI method needed the correct native accessibility getter/link-role lookup. The subsequent 13-method UI pass succeeded in 103.89 seconds. After the finish layout correction, the four affected UI methods succeeded in 90.64 seconds. Total test command wall time, including preparation and retries: 473.01 seconds. No full test suite was run.

Changed executable-line coverage: **544 / 590 (92.2%)**. Coverage uses the last validating phase for each file, avoiding cross-version profile merges. See `docs/evidence/onboarding-workbench/coverage.json` and `validation.json`. This is changed-code coverage, not project-wide coverage.

Live acceptance opened the existing login window and speech editor, passed actual connection probes for the configured Doubao and language services without Typeflux login, confirmed a skip without deleting existing models, traversed the guides and inspected the finish page. The final installed build's three core pages and native provider menu were reviewed after the typography changes. Scoped onboarding/language/appearance preferences were restored.

Validation scope stops at connection probes and UI/routing behavior: no Typeflux account sign-in or microphone dictation session was completed during this pass.

## Implementation checklist

- [x] Selected workbench layout and shared native controls implemented.
- [x] Optional Cloud/custom/launcher routes and capability-aware skip confirmation preserved.
- [x] Finish, menu-bar, Settings and feature-specific configuration recovery retained.
- [x] Long-content title/footer bounds fixed and verified.
- [x] Focused tests, changed-line coverage, strict SwiftLint and whitespace checks passed.
- [x] Final installed native pages inspected and comparison evidence archived.

final result: passed
