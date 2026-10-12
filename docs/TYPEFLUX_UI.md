# TypefluxUI

`TypefluxUI` is a SwiftPM library target with no dependency on the application,
settings storage, networking or localization. Its design reference is UI System
§2–§5 in `docs/design/ui-system.md`.

New components use `TypefluxColor` for system semantic colors and
`TypefluxTextStyle` for `Font.TextStyle`. The accent follows
`NSColor.controlAccentColor`. Native controls retain their native sizing; the
radius, height, width and spacing tables are reference metrics for custom
navigation surfaces, Spotlight and HUDs.

Resolve tokens from the view's `interfaceStyle`, `colorScheme`,
`accessibilityReduceTransparency` and `colorSchemeContrast`:

```swift
let tokens = TypefluxTokens(
    style: style,
    colorScheme: colorScheme,
    reduceTransparency: reduceTransparency,
    increasedContrast: contrast == .increased,
    layer: .navigation
)
```

Content uses `.content` and always resolves to `.opaque`. Navigation resolves
to Liquid Glass on macOS 26 with a supporting compiler, visual effects on
earlier systems, or opaque surfaces for Classic and either accessibility
override. The renderer also enforces these accessibility overrides even if a
caller explicitly requests glass.

The application keeps its localization, settings observer and persistence.
`InterfaceStyle` keeps the `classic` / `liquidGlass` raw values, and the stored
key remains `ui.overlayStyle`. `LiquidGlassIntensity` preserves normalization
and rendering values. The deprecated `StudioTheme`, `AskTheme` and
`ModelVisualStyle` adapters preserve the frozen legacy palette and page
metrics; migrating a page to semantic tokens is a separate visual change.

In debug builds, open **Dev → Component Gallery** in the menu bar. The window
has independent style and appearance pickers, without changing saved settings.
Gallery prose is supplied through `TypefluxGalleryLabels` by the caller.

The navigation section now demonstrates window templates, collapsed/expanded/
filtering/disabled search, inline picker search, populated/empty Spotlight panels,
HUDs, sheet footers, alerts and confirmation dialogs. Click the presentation
buttons to exercise their native behavior. Pass additional component sections
through the gallery's `components` builder.

`TypefluxWindow` wraps `NavigationSplitView`, a native sidebar `List`, a toolbar
title, action groups, one optional prominent action and the rightmost native
toolbar search. The caller owns selection, query state, data and all strings.
Keep content solid; put a centered grouped form or reading column in the detail
builder. Add optional principal toolbar controls through SwiftUI's `.toolbar`.

`typefluxSearchable(state:prompt:)` wraps `.searchable(placement: .toolbar)` and
observes its `NSSearchToolbarItem` without replacing SwiftUI's delegate. The
native item owns its system morph. `TypefluxToolbarSearch` offers the same state
contract for custom navigation surfaces, using `NSSearchField` and, on macOS 26,
`GlassEffectContainer`/`glassEffectID` for the circle-to-capsule morph. Use one
active toolbar search per window. Both share `TypefluxSearchState`: click/⌘F
focuses, Escape clears before collapsing, empty blur collapses, and a query
retains the expanded field. Escape is left to the input method during marked
text composition. `TypefluxInlineSearch` is the small always-visible exception
for menus, popovers and pickers.

`TypefluxGlassContainer` and `TypefluxGlassGroup` use system glass on 26,
`NSVisualEffectView` on earlier macOS, and opaque navigation backgrounds for
Classic, Reduce Transparency or Increase Contrast. `TypefluxAccessibilityOptions`
can simulate the two accessibility settings in the gallery/snapshots; simulation
is combined with the real settings using OR, so it cannot turn them off.

`TypefluxSpotlightPanel` accepts caller-filtered results and mode bindings.
Arrow keys skip disabled results; Return activates; ⌘Return requests plain text;
⌘1–9 activates the corresponding visible result; Escape requests dismissal.
Selection survives reorder and falls back when a result disappears. Local key
monitors operate only in their own window, yield during marked text input and
attached sheets, and are removed when the view is dismantled. Classic uses one
panel; Liquid Glass separates the capsule, circular mode buttons and results.

`TypefluxHUDState.present` replaces any previous confirmation and dismisses
after 1.5 seconds. Timers are cancelled on replacement, dismissal and destruction;
the `typefluxHUD` modifier also dismisses when its host disappears. Use a HUD
only for confirmations with no in-place context.

`typefluxSheet` uses a compact headline and trailing footer: Cancel on the left,
default action on the right. Escape cancels; Return confirms when enabled.
Returning false from `confirm` preserves the sheet for validation feedback.
`typefluxAlert`/`typefluxConfirmationDialog` use native presentation and roles;
the system owns button order there. Pass `.destructive` for destructive actions.

Build and verification on macOS:

```sh
swift build --target TypefluxUI
swift build
swift test --enable-code-coverage --filter 'TypefluxUI|InterfaceStyleTests|LiquidGlassIntensityTests|AskGlassTests'
swift test
```

`Tests/TypefluxTests/TypefluxUISnapshot.swift` provides `renderMatrix` for any
SwiftUI view. Call it from a main actor suite with `.exclusiveUIState`. It
renders Classic / Liquid Glass × Light / Dark, with explicit SwiftUI and
AppKit appearances, animation disabled, and 2× PNG output. Windows are closed
after every render. Bitmap snapshots use an opaque material override because
AppKit caching cannot capture the window server's glass compositor; native
glass needs a live window check in addition to these deterministic PNGs.

```sh
TYPEFLUX_UI_SNAPSHOTS=artifacts/ui swift test --filter 'TypefluxUICompatibilityVisualTests|TypefluxUIGalleryTests'
TYPEFLUX_UI_GALLERY_LIVE=1 TYPEFLUX_UI_SNAPSHOTS=artifacts/ui swift test --filter 'TypefluxUIGalleryTests.*dev menu'
```

The compatibility scenes use isolated synthetic Ask data and a production
settings row. They access no account, microphone or screen content.

The live menu/window check runs in a separate process: the current SwiftPM
async test runner exits early if more renders follow that native lifecycle.
Combine its coverage profile with the normal test run when measuring coverage.

Content controls are wrapped by `TypefluxButton` (primary, regular, destructive,
borderless, link; native control sizes and an opt-in default Return action),
`TypefluxIconButton`, `TypefluxPopup`, `TypefluxMenu`,
`TypefluxSegmentedControl`, `TypefluxSwitch`, `TypefluxCheckbox`,
`TypefluxRadioGroup`, `TypefluxSlider`, `TypefluxTextField` and `TypefluxProgress`.
Callers pass localized strings and bindings and use `.disabled`, `.focused`,
`.onSubmit` and keyboard shortcuts as needed. Do not restyle these controls at
call sites. Native Tahoe controls keep their shape in both interface styles.

`TypefluxForm`, `TypefluxFormSection`, `TypefluxSettingsRow` and
`TypefluxNavigationRow` wrap grouped forms and labeled rows. Forms have a 640pt
maximum width. Navigation rows take an action so the application owns routing.
`TypefluxEmptyState` uses the native unavailable view on macOS 14+ and a solid
compatibility layout on macOS 13. `typefluxHelp` uses the native help tag.

`TypefluxTable` owns native sorting, multiple selection and alternating rows.
Use `TypefluxTableCell(rowID:)` in every column and
`TypefluxTableActions(rowID:selected:)` in the trailing column to reveal actions
when any cell is hovered, the row is selected, the action group is keyboard
focused, or VoiceOver is enabled. Pass selection membership through `selected`.
Actions stay available through native keyboard selection without requiring hover.

`TypefluxStatus`, `TypefluxTag`, `TypefluxToken` and `TypefluxKeyHint` use semantic
colors. Tags are read-only metadata; tokens represent attachments or context
and optionally offer an accessible native remove button. Supply spoken shortcut
and remove labels explicitly. Slider and progress inputs normalize nonfinite and
out-of-range display values without writing to model bindings while rendering.

The gallery's content section uses synthetic English developer examples. Each
section includes live and disabled samples; hovering, holding and focusing the
live sample reports the state while the OS draws the control. Read-only status,
tags, key hints and progress have no press/focus interaction.

```sh
# Run each UI suite in a separate process to isolate native window lifecycles.
TYPEFLUX_UI_SNAPSHOTS=artifacts/content swift test --no-parallel --enable-code-coverage \
  --filter TypefluxUIControlsVisualTests
swift test --no-parallel --enable-code-coverage --filter TypefluxUIControlsBehaviorTests
swift test --no-parallel --enable-code-coverage --filter TypefluxUIControlsTableTests
swift test --no-parallel --enable-code-coverage --filter TypefluxUIControlStateTests
```

Only the related suites are required for this content-control change. The full
suite is reserved for acceptance after all UI-unification sub-issues are complete.

Native menu tracking follows `SettingsMenuPickerTests`: run the menu checks in
an independent test process. SwiftUI creates the items only when tracking starts.
Save each suite’s coverage profile before the next run and merge the profiles.

```sh
TYPEFLUX_UI_CONTENT_MENUS=1 swift test --no-parallel --enable-code-coverage \
  --filter TypefluxUIControlsMenuTests
```

The snapshot helper sets the control activity to `.key` so native controls show
the active accent rather than the inactive window palette. High-contrast renders
use AppKit's accessibility appearances; read-only system accessibility preferences
are never changed by the tests.

Navigation validation runs only related tests at this rollout stage (the full
suite runs once at final acceptance):

```sh
swift build
TYPEFLUX_UI_SNAPSHOTS=artifacts/ui swift test --no-parallel --enable-code-coverage \
  --filter 'TypefluxNavigationStateTests|TypefluxNavigationVisualTests|TypefluxUIGalleryTests'
TYPEFLUX_UI_NAVIGATION_LIVE=1 TYPEFLUX_UI_SNAPSHOTS=artifacts/ui \
  swift test --no-parallel --enable-code-coverage \
  --filter 'TypefluxNavigationInteractionTests|TypefluxPresentationInteractionTests'
```

Preserve each run's coverage profile and merge with `llvm-profdata` before
exporting with `llvm-cov`. The native tests cache window frames and Spotlight
in the four style/appearance combinations; the bitmap tests also
capture Reduce Transparency and Increase Contrast. Native controls follow the
installed OS, so Classic on macOS 26+ still has Tahoe control shapes. Frame
caching also cannot record the WindowServer glass compositor.
Set `TYPEFLUX_UI_CAPTURE_LIVE=1` for additional `-live.png` window captures on
a worker with Screen Recording access.
The SwiftPM runner does not provide an active application event loop. Native
default/cancel shortcuts are verified with `NSWindow.performKeyEquivalent`, and
the search bridge explicitly begins the native toolbar item's search interaction
for a scoped ⌘F event. Tests also check the state produced by native editing and
Escape events; they do not infer behavior from a successful event submission.
