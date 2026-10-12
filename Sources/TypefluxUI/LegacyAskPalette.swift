import AppKit
import SwiftUI

/// Frozen compatibility values for the existing conversation and launcher.
public enum LegacyAskPalette {
    public static let accent = LegacyStudioPalette.accent

    // Neutral greys chosen to match the settings window (`LegacyStudioPalette.shellSurface`
    // and `sidebar` composited over their material); opaque on purpose.
    public static let surface = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0.985, alpha: 1),
        dark: NSColor(calibratedWhite: 0.122, alpha: 1)
    )
    /// One step above `surface`: composer footer, tool cards, inline banners.
    public static let raisedSurface = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0.965, alpha: 1),
        dark: NSColor(calibratedWhite: 0.150, alpha: 1)
    )
    public static let sidebarSurface = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0.940, alpha: 1),
        dark: NSColor(calibratedWhite: 0.075, alpha: 1)
    )
    public static let controlSurface = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0.925, alpha: 1),
        dark: NSColor(calibratedWhite: 0.180, alpha: 1)
    )
    public static let border = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10)
    )
    public static let separator = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )
    public static let accentSoft = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedRed: 0.906, green: 0.937, blue: 1.0, alpha: 1),
        dark: NSColor(calibratedRed: 0.082, green: 0.149, blue: 0.243, alpha: 1)
    )
    /// Marks conversations kept on this Mac (the lock icon, the header chip).
    public static let privateTint = privateColor(lightAlpha: 1, darkAlpha: 1)
    public static let privateFill = privateColor(lightAlpha: 0.10, darkAlpha: 0.13)
    public static let privateHeaderFill = privateColor(lightAlpha: 0.10, darkAlpha: 0.12)

    /// Resolve the system colour in the requested appearance before returning
    /// it from a dynamic provider; a nested semantic colour can retain Aqua.
    private static func privateColor(lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else {
                return NSColor(srgbRed: 147 / 255, green: 51 / 255, blue: 234 / 255, alpha: lightAlpha)
            }
            var resolved = NSColor.systemPurple
            appearance.performAsCurrentDrawingAppearance {
                resolved = (NSColor.systemPurple.usingColorSpace(.sRGB) ?? .systemPurple)
                    .withAlphaComponent(darkAlpha)
            }
            return resolved
        })
    }

    public static let accentText = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 29 / 255, green: 78 / 255, blue: 216 / 255, alpha: 1),
        dark: NSColor(calibratedRed: 0.557, green: 0.741, blue: 1.0, alpha: 1)
    )
    public static let successSoft = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedRed: 0.894, green: 0.965, blue: 0.929, alpha: 1),
        dark: NSColor(calibratedRed: 0.071, green: 0.161, blue: 0.114, alpha: 1)
    )
    public static let warningSoft = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedRed: 0.984, green: 0.941, blue: 0.882, alpha: 1),
        dark: NSColor(calibratedRed: 0.165, green: 0.125, blue: 0.082, alpha: 1)
    )
    public static let dangerSoft = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedRed: 0.984, green: 0.918, blue: 0.918, alpha: 1),
        dark: NSColor(calibratedRed: 0.173, green: 0.094, blue: 0.094, alpha: 1)
    )
    // Design-board values are specified in sRGB. `calibratedWhite` uses the
    // gamma 1.8 generic grey space, so 0.18 there renders as #3D3D3D, not #2E2E2E.

    /// The workspace composer card and empty-state cards: one step lighter than
    /// the transcript canvas in dark, plain white in light.
    public static let composerSurface = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.180, blue: 0.180, alpha: 1)
    )
    /// The floating launcher's frost and opaque fallback. A deeper neutral in
    /// dark mode keeps bright windows behind the panel from washing out its text;
    /// a cool off-white in light mode keeps the glass from reading as paper.
    public static let launcherSurface = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.980, alpha: 1),
        dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.110, alpha: 1)
    )
    /// Neutral diffuse glass in both appearances. The opaque accessibility
    /// fallback keeps its brighter reading surface in `launcherSurface`.
    public static let launcherGlassTint = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 226 / 255, green: 226 / 255, blue: 226 / 255, alpha: 1),
        dark: NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
    )
    /// Popovers opened from the composer (model and reasoning choosers).
    public static let popoverSurface = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1)
    )
    /// Cards inside the usage panel, one step above the panel itself.
    public static let panelCard = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.239, green: 0.239, blue: 0.239, alpha: 1)
    )
    /// Recessed track behind the usage panel's segmented control.
    public static let segmentTrack = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0.918, green: 0.922, blue: 0.933, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.180, blue: 0.180, alpha: 1)
    )
    /// The launcher's idle edge. It floats over arbitrary windows, so it needs a
    /// firmer outline than the workspace composer's `border` to read as a panel.
    public static let floatingBorder = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.12),
        dark: NSColor(calibratedWhite: 1, alpha: 0.18)
    )
    /// The launcher's hairline on glass. The light card is clear enough to vanish
    /// into a white window without it; dark glass keeps its own rim.
    public static let floatingGlassEdge = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08),
        dark: .clear
    )

    // The launcher's own washes. Its card is glass over arbitrary windows, so in
    // light mode these are translucent and take on the backdrop instead of
    // pasting opaque greys on it. Dark mode uses neutral launcher washes.

    /// Rules inside the launcher: under the editor and above its bottom bar.
    public static let launcherSeparator = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.08),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.04)
    )
    /// The highlighted home row or keyword chip, outlined by `launcherSelectionEdge`.
    public static let launcherSelection = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10),
        dark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1)
    )
    public static let launcherSelectionEdge = LegacyStudioPalette.dynamic(
        light: .clear,
        dark: .clear
    )
    /// The `fy`, `dict` keyword labels.
    public static let launcherKeyword = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06),
        dark: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.22, alpha: 0.72)
    )
    public static let launcherKeywordText = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.27, alpha: 1),
        dark: NSColor(srgbRed: 0.70, green: 0.70, blue: 0.70, alpha: 1)
    )
    /// A neutral row icon's tile: a subtle raised wash over the glass.
    public static let launcherTile = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24),
        dark: NSColor(calibratedWhite: 0.720, alpha: 0.14)
    )
    public static let launcherTileEdge = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.04),
        dark: .clear
    )
    /// Keyword chips at rest.
    public static let launcherChipFill = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08),
        dark: .clear
    )
    public static let launcherChipEdge = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)
    )
    /// The ⌘1…⌘9 badges: white keycaps in light mode, an outline in dark.
    public static let launcherShortcutFill = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: .clear
    )
    public static let launcherShortcutEdge = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.14),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )
    /// Times, shortcut badges and key hints stay readable over neutral selections.
    public static let launcherMetaText = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.27, alpha: 1),
        dark: NSColor(srgbRed: 0.65, green: 0.65, blue: 0.65, alpha: 1)
    )
    public static let launcherPlaceholderText = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 0.47, green: 0.47, blue: 0.47, alpha: 1),
        dark: NSColor(srgbRed: 0.52, green: 0.52, blue: 0.52, alpha: 1)
    )
    /// A footer switch that is on (screenshot, memory): a tinted well behind the
    /// accent icon, so "on" reads by shape as well as colour.
    public static let switchOnFill = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 0.10),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 0.22)
    )
    public static let switchOnEdge = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 0.20),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 0.35)
    )
    /// The design board's glass tint for in-window panels (sidebar, header
    /// pills, composer): a cool graphite in dark, white in light. Frosted at
    /// `AskGlassPlacement.inWindow.frost(dark:)`, so the backdrop's glows show through.
    public static let glassFill = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.204, alpha: 1)
    )
    /// The pressed (or hovered field) wash, one step above `hoverFill`.
    public static let pressFill = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.09),
        dark: NSColor(calibratedWhite: 1, alpha: 0.12)
    )
    /// Translucent hover wash, so borderless controls read the same on any surface.
    public static let hoverFill = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    public static let monoSurface = LegacyStudioPalette.dynamic(
        light: NSColor(calibratedRed: 0.957, green: 0.965, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.063, green: 0.071, blue: 0.086, alpha: 1)
    )

    /// Hairlines group white cards and divide the library's reading column.
    public static let cardBorder = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.09),
        dark: NSColor(calibratedWhite: 1, alpha: 0.10)
    )
    public static let librarySeparator = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1, alpha: 0.07)
    )
    public static let noteQuestionSurface = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(calibratedWhite: 1, alpha: 0.048)
    )
    public static let keycapSurface = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    public static let userBubble = LegacyStudioPalette.dynamic(
        light: NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 0.08),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1, alpha: 0.18)
    )
    public static let userBubbleEdge = LegacyStudioPalette.dynamic(
        light: .clear,
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1, alpha: 0.42)
    )

}
