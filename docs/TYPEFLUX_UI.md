# TypefluxUI

`TypefluxUI` is a SwiftPM library target with no dependency on the application,
settings storage, networking or localization. Its design reference is UI System
§2–§4 in `docs/design/ui-system.md`.

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
