import AppKit
import SwiftUI

/// What the launcher card is made of. Liquid Glass exists only on macOS 26, so
/// earlier systems fall back to the adaptive popover blur, and Reduce Transparency
/// restores the opaque surface on every version.
enum AskGlassMaterial: Equatable {
    /// macOS 26+: system Liquid Glass with its own refraction and highlights.
    case liquidGlass
    /// macOS 13–15: `NSVisualEffectView(.popover)` blending with the desktop behind the panel.
    case visualEffect
    /// Reduce Transparency: the surface's opaque fill.
    case opaque

    static func resolve(reduceTransparency: Bool,
                        supportsLiquidGlass: Bool = systemSupportsLiquidGlass) -> AskGlassMaterial {
        if reduceTransparency { return .opaque }
        return supportsLiquidGlass ? .liquidGlass : .visualEffect
    }

    /// True when this build and the running system both have the Liquid Glass API.
    /// An older compiler cannot reference it, so such builds always fall back.
    static var systemSupportsLiquidGlass: Bool {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Translucent materials draw their own rim; only the opaque fill needs the
    /// card's border to separate it from the window behind.
    var drawsOwnEdge: Bool { self != .opaque }

    /// The card's idle outline: none on glass, except with Increase Contrast,
    /// where a firm edge matters more than the material's soft rim.
    func idleBorder(_ border: Color, increasedContrast: Bool) -> Color {
        drawsOwnEdge && !increasedContrast ? .clear : border
    }
}

/// Where a glass surface sits, which decides what the pre-macOS 26 blur samples.
/// Liquid Glass picks this up on its own; `NSVisualEffectView` has to be told.
enum AskGlassPlacement: Equatable {
    /// A panel of its own over other apps (the launcher, menus, hover cards):
    /// it blurs the desktop and windows behind it.
    case floating
    /// Chrome floating over the conversation window's own content (the
    /// workspace composer, sidebar, header and palette): it blurs the transcript.
    case inWindow
    /// The composer's menus and hover cards: a panel over the window, frosted
    /// enough that the rows stay legible over a busy transcript.
    case menu

    var blending: NSVisualEffectView.BlendingMode { self == .inWindow ? .withinWindow : .behindWindow }
    /// How much of the surface's own fill frosts the glass. Clear glass over the
    /// transcript let black text show through the composer and made the header
    /// pills vanish on a white window. Floating panels and menus need a stable
    /// light backplate over busy windows while retaining a little translucency.
    func frost(dark: Bool) -> Double {
        switch self {
        case .floating: return dark ? 0.78 : 0.88
        case .inWindow: return 0.45
        case .menu: return dark ? 0.6 : 0.90
        }
    }
    /// Adaptive popover material avoids the HUD's grey cast in light mode.
    var fallbackMaterial: NSVisualEffectView.Material {
        switch self {
        case .floating: return .popover
        case .inWindow: return .popover
        case .menu: return .menu
        }
    }
}

extension EnvironmentValues {
    /// Pins the launcher material, e.g. to check the Reduce Transparency fallback
    /// in tests; nil follows the system.
    @Entry var askGlassMaterialOverride: AskGlassMaterial? = nil
}

/// The launcher's floating card. It replaces the opaque `launcherSurface`
/// with glass so the panel reads as part of whatever window it floats over.
struct AskGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var material: AskGlassMaterial
    var corner: CGFloat
    /// Frosts translucent glass and fills the card when transparency is reduced.
    var opaqueFill: Color
    var placement: AskGlassPlacement = .floating
    /// `.circular` for pills: a continuous corner near half the height draws a
    /// stray sliver at each end of the outline.
    var cornerStyle: RoundedCornerStyle = .continuous

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: cornerStyle) }

    var body: some View {
        ZStack {
            switch material {
            case .liquidGlass:
                liquidGlass
                frosting
            case .visualEffect:
                fallback
                frosting
            case .opaque:
                shape.fill(opaqueFill)
            }
        }
        .clipShape(shape)
        .overlay {
            // macOS 26 glass lights its own edge; the fallback blur gets a drawn specular rim instead.
            if material == .visualEffect { rim }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var liquidGlass: some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                AskLiquidGlassView(cornerRadius: corner)
            } else {
                fallback
            }
        #else
            fallback
        #endif
    }

    @ViewBuilder private var frosting: some View {
        shape.fill(opaqueFill.opacity(placement.frost(dark: colorScheme == .dark)))
    }

    private var fallback: some View {
        StudioVisualEffectBlur(material: placement.fallbackMaterial, blendingMode: placement.blending,
                               cornerRadius: corner)
    }

    /// Bright on the light-facing corner, fading along the edge.
    private var rim: some View {
        shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: StudioTheme.glassStrokeHighlight, location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.7),
                    .init(color: StudioTheme.glassStrokeHighlight.opacity(0.4), location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
    }
}

#if compiler(>=6.2)
    /// System Liquid Glass as its own AppKit layer. SwiftUI's `glassEffect` sat in
    /// the same render tree as the composer, so every frame of the recording
    /// waveform re-composited the glass and the panel flickered.
    @available(macOS 26.0, *)
    private struct AskLiquidGlassView: NSViewRepresentable {
        var cornerRadius: CGFloat

        func makeNSView(context _: Context) -> NSGlassEffectView {
            let view = NSGlassEffectView()
            view.cornerRadius = cornerRadius
            return view
        }

        func updateNSView(_ view: NSGlassEffectView, context _: Context) {
            if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
        }
    }
#endif

/// A floating glass card: the chips' hover cards and the composer's menus.
/// Glass on macOS 26 and the adaptive popover blur before it; with Reduce Transparency an
/// opaque popover surface with a hairline border.
struct AskGlassCardSurface<Content: View>: View {
    static var hoverCardCorner: CGFloat { 14 }
    /// Concentric with the 12pt menu rows inset by 6.
    static var menuCorner: CGFloat { 18 }

    var corner: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var materialOverride
    @Environment(\.colorSchemeContrast) private var contrast
    let content: Content

    init(corner: CGFloat = Self.hoverCardCorner, @ViewBuilder content: () -> Content) {
        self.corner = corner
        self.content = content()
    }

    var body: some View {
        let material = materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency)
        content
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .background(AskGlassBackground(material: material, corner: corner, opaqueFill: AskTheme.popoverSurface,
                                           placement: .menu))
            .overlay {
                if !material.drawsOwnEdge || contrast == .increased {
                    RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(AskTheme.border)
                }
            }
    }
}

/// Glass for chrome that floats over the conversation window's own content,
/// frosted with `opaqueFill` and outlined with a hairline. With Reduce
/// Transparency (or a pinned `.opaque` material) it is `opaqueFill` alone.
struct AskInWindowGlass: ViewModifier {
    var corner: CGFloat
    var opaqueFill: Color
    var cornerStyle: RoundedCornerStyle = .continuous
    /// The drop shadow it floats on; nil for glass that sits inside another surface.
    var elevation: AskElevation? = .panel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var materialOverride
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: cornerStyle) }

    func body(content: Content) -> some View {
        let material = materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency)
        content
            .background(AskGlassBackground(material: material, corner: corner, opaqueFill: opaqueFill,
                                           placement: .inWindow, cornerStyle: cornerStyle))
            .background {
                if let elevation { AskOuterShadow(shape: shape, elevation: elevation) }
            }
            // Always outlined, unlike the launcher: frosted with the window's own
            // colours, the pills and cards would otherwise vanish on a white window.
            .overlay(shape.strokeBorder(AskTheme.border).allowsHitTesting(false))
            // The rim catches the light on its top-leading edge, as glass does.
            .overlay(shape.strokeBorder(AskRimLight.gradient(dark: colorScheme == .dark), lineWidth: 1)
                .allowsHitTesting(false))
    }
}

/// The light along a glass edge: bright toward the top-leading corner, fading
/// along the sides, with a fainter return at the bottom-trailing corner.
enum AskRimLight {
    static func strength(dark: Bool) -> (lit: Double, back: Double) { dark ? (0.30, 0.10) : (0.9, 0.45) }

    static func gradient(dark: Bool) -> LinearGradient {
        let value = strength(dark: dark)
        return LinearGradient(stops: [
            .init(color: Color.white.opacity(value.lit), location: 0),
            .init(color: .clear, location: 0.34),
            .init(color: .clear, location: 0.64),
            .init(color: Color.white.opacity(value.back), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    func askInWindowGlass(corner: CGFloat, opaqueFill: Color = AskTheme.glassFill,
                          elevation: AskElevation? = .panel) -> some View {
        modifier(AskInWindowGlass(corner: corner, opaqueFill: opaqueFill, elevation: elevation))
    }

    /// A pill of the given height: header capsules and the stop button.
    func askInWindowGlassPill(height: CGFloat) -> some View {
        modifier(AskInWindowGlass(corner: height / 2, opaqueFill: AskTheme.glassFill, cornerStyle: .circular,
                                  elevation: .control))
    }
}
