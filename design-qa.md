# Persona Library Design QA — 2026-08-28

## Scope and evidence

- Target: approved final persona-library mockup, `/Users/mylxsw/.codex/generated_images/01a043ac-6dbd-7c40-8c92-db615d4cf01d/exec-89e92c8b-ab19-4378-92af-2105d4a39ffc.png` (1448 x 1086 pixels).
- Full native render: `/Users/mylxsw/.codex/visualizations/2026/08/27/01a043ac-6dbd-7c40-8c92-db615d4cf01d/persona-library-implementation/full-native-render.png` (2200 x 1600 pixels, 1100 x 800 points at 2x).
- Focused native render: `/Users/mylxsw/.codex/visualizations/2026/08/27/01a043ac-6dbd-7c40-8c92-db615d4cf01d/persona-library-implementation/editor-native-render.png` (1780 x 1408 pixels, 890 x 704 points at 2x).
- Both implementation images were captured from the actual SwiftUI views using NSHostingView, synthetic persona data, and an isolated UserDefaults suite. They are NOT captures of interactive operation in the signed app. Temporary capture code was removed afterward.
- State: dark appearance, Simplified Chinese, Native English Speaker selected and default, unsaved draft, name and definition visible. The synthetic custom persona text is the same writing example as the design. Custom list previews use actual prompt content; no summary is fabricated or persisted.
- Comparison: the full native render and reference were opened together in one comparison input; the focused native render and reference were likewise opened together. The reference includes a macOS frame and outer canvas; native renders exclude that chrome. Compare app-owned content at logical scale (native 2x); ignore the existing sidebar, account state, and test-host version string.

## Required fidelity surfaces

- Typography: existing system font tokens; 22pt page heading, 15pt editor heading, 13pt input/body/list names, 12pt labels, 11pt preview text. The prompt is proportional rather than monospaced. This keeps the page consistent with the rest of the production app.
- Layout: unbordered grouped roster, fixed search field, separate scrolling list and text editor, selected row fill, bounded editor, and visible footer. The page uses the window viewport instead of growing with the prompt. A layout regression test renders a 100-line definition at 842 x 436 and 1000 x 668 points and verifies the text viewport leaves room for the footer.
- Colors: existing StudioTheme surfaces and borders rather than the generated image's variable material shading. Blue editing selection is separate from the green default mark. The default button retains its text and turns green for the active default.
- Assets: native SF Symbols for search, no-persona, and circle-check; existing initial badges and global sidebar reused. No raster mockup is embedded in the UI.
- Copy: no purpose field or editing-type subtitle; built-in/custom groups, localized search/empty/read-only/unsaved states, and Save Changes in all five supported locales.

## Findings and verification boundary

- The native rendered layout has no observed clipping or actionable P0/P1/P2 visual mismatch. Built-in personas remain read-only; saved custom definitions and default behavior are preserved.
- Unit tests cover grouping, search including localized summaries, default versus editing state, disabled rewrite, creation from search, save/cancel, and preserving drafts when setting the default.
- Final `swift test` passed: 2461 XCTest tests plus 8 Swift Testing tests (2469 total), zero failures. Logs: `/tmp/typeflux-persona-final-tests.log`.
- `swift build` and the final signed `make run` workflow succeeded. The app was launched. Build log: `/tmp/typeflux-persona-final-run.log`.
- Computer Use can read the signed app but every click fails with `Sky Computer Use native pipe closed before response`. Keyboard Tab did not navigate. Consequently the actual app's persona navigation, resizing, and clicking Save/Set Default have NOT been manually verified in this run.
- The user was asked to open the Personas page so live capture can continue. No account, persona, or cloud data was changed by interactive testing.
- Formatting automation is unavailable: `swiftformat` is not installed. Changes were checked with `git diff --check`.

## Remaining check checklist

- Open the signed app's Personas page and inspect the full window.
- Exercise search, select, default, edit/save/cancel, and app-specific persona entry.
- Resize to the smallest supported window and check footer visibility and long-text scrolling.

The implementation and automated checks are complete; full interactive design QA remains blocked by the click tool.

final result: blocked

---

<details>
<summary>Earlier account-page QA (archived)</summary>

# Design QA

- Source visual truth: `/var/folders/2b/zzmzm98j5dj0y7kshprwwjkh0000gn/T/codex-clipboard-a095be40-3223-4e06-9cf5-8d43b8ed69c9.png`
- Signed-in implementation screenshot: `/tmp/typeflux-account-number-avatar-final.png`
- Signed-out implementation screenshot: `/tmp/typeflux-account-avatar-signed-out-final.png`
- Full comparison: `/tmp/typeflux-account-number-avatar-full-comparison.png`
- Credit formatting comparison: `/tmp/typeflux-account-credit-focused-comparison.png`
- Avatar source-versus-fix comparison: `/tmp/typeflux-account-avatar-focused-comparison.png`
- Avatar state comparison: `/tmp/typeflux-account-avatar-states-comparison.png`
- Source pixels: `2420 x 1692`
- Implementation pixels: `1056 x 768`
- Rendered app viewport: packaged Typeflux settings window configured at `1100 x 800` points and constrained to `1056 x 768` pixels by the active display.
- Density normalization: the source was proportionally scaled and padded to `1056 x 768` for full-view comparison. Focused credit and sidebar-card crops were separately normalized to equal dimensions before comparison.
- State: dark appearance; signed-in Pro account with finite Cloud credits, plus a signed-out card state.

## Full-view comparison evidence

The implementation preserves the approved Account page layout, sidebar card proportions, spacing, typography, colors, and subscription hierarchy. The requested changes are limited to numeric precision and the account-state avatar symbol.

## Focused region comparison evidence

- Credit values changed from `87,025.00`, `2,975.00`, and `90,000.00` to `87,025`, `2,975`, and `90,000`. Values with a fractional component retain up to two rounded decimal places.
- The earlier signed-in card used the outline `person.circle`. The implementation now uses `person.circle.fill` while preserving the same size, color, baseline, and spacing.
- The state comparison confirms that Guest keeps the outline avatar and a signed-in account receives the filled avatar.

## Required fidelity surfaces

- Fonts and typography: no font family, weight, size, line-height, wrapping, or truncation behavior changed.
- Spacing and layout rhythm: the icon occupies the same frame, so card padding and text alignment remain unchanged.
- Colors and visual tokens: both avatar variants retain the existing identity color for their state.
- Image quality and asset fidelity: native SF Symbols are used for both outline and filled variants; no replacement assets were introduced.
- Copy and content: no localized copy changed; only redundant decimal zeros were removed from credit values.

## Findings and fixes

- [P2] Credit amounts always forced two decimal places, creating visual noise for whole numbers. Fix: use zero minimum and two maximum fraction digits with half-up rounding and grouping separators.
- [P2] Signed-in and signed-out cards both used the outline account symbol. Fix: select `person.circle.fill` for every authenticated/loading account state and retain `person.circle` for signed out.
- Post-fix focused comparisons show the values and avatar states clearly without layout movement or clipping.
- No actionable P0, P1, or P2 differences remain.

## Interaction and accessibility checks

- The avatar remains hidden from accessibility because the identity button already supplies the `View account` label.
- The username, Manage/Sign in action, and footer controls retain their existing hit targets and behavior.
- The filled avatar applies to loading and unavailable signed-in states as well as the resolved account state, avoiding a temporary visual regression during refresh.

## Verification

- Focused formatter and sidebar-presentation tests passed: 13 tests, 0 failures.
- Full test suite passed: 2398 tests, 0 failures.
- Packaged-app signed-in and signed-out states were visually inspected.
- Full and focused comparison images were inspected.
- Temporary preview hooks were removed before the final production build.

final result: passed

</details>
