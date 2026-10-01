import AppKit
import SwiftUI

/// What the launcher card is made of. Liquid Glass exists only on macOS 26, so
/// earlier systems fall back to the system HUD blur, and Reduce Transparency
/// restores the opaque composer surface on every version.
enum AskGlassMaterial: Equatable {
    /// macOS 26+: system Liquid Glass with its own refraction and highlights.
    case liquidGlass
    /// macOS 13–15: `NSVisualEffectView(.hudWindow)` blending with the desktop behind the panel.
    case visualEffect
    /// Reduce Transparency: the workspace composer's opaque fill.
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

    var blending: NSVisualEffectView.BlendingMode { self == .floating ? .behindWindow : .withinWindow }
    /// The HUD material reads as a dark sheet over the light window, so in-window
    /// chrome uses the adaptive popover material instead.
    var fallbackMaterial: NSVisualEffectView.Material { self == .floating ? .hudWindow : .popover }
}

extension EnvironmentValues {
    /// Pins the launcher material, e.g. to check the Reduce Transparency fallback
    /// in tests; nil follows the system.
    @Entry var askGlassMaterialOverride: AskGlassMaterial? = nil
}

/// The launcher's floating card. It replaces the opaque `composerSurface`
/// with glass so the panel reads as part of whatever window it floats over.
struct AskGlassBackground: View {
    var material: AskGlassMaterial
    var corner: CGFloat
    /// Used when transparency is reduced.
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
            case .visualEffect:
                fallback
            case .opaque:
                shape.fill(opaqueFill)
            }
        }
        .clipShape(shape)
        .overlay {
            // macOS 26 glass lights its own edge; the HUD blur gets a drawn specular rim instead.
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
/// Glass on macOS 26 and the HUD blur before it; with Reduce Transparency an
/// opaque popover surface with a hairline border.
struct AskGlassCardSurface<Content: View>: View {
    static var hoverCardCorner: CGFloat { 14 }
    /// Concentric with the 12pt menu rows inset by 6.
    static var menuCorner: CGFloat { 18 }

    var corner: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var materialOverride
    let content: Content

    init(corner: CGFloat = Self.hoverCardCorner, @ViewBuilder content: () -> Content) {
        self.corner = corner
        self.content = content()
    }

    var body: some View {
        let material = materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency)
        content
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .background(AskGlassBackground(material: material, corner: corner, opaqueFill: AskTheme.popoverSurface))
            .overlay {
                if !material.drawsOwnEdge {
                    RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(AskTheme.border)
                }
            }
    }
}

/// Glass for chrome that floats over the conversation window's own content.
/// With Reduce Transparency (or a pinned `.opaque` material) it falls back to
/// `opaqueFill` with a hairline border, like the launcher card.
struct AskInWindowGlass: ViewModifier {
    var corner: CGFloat
    var opaqueFill: Color
    var cornerStyle: RoundedCornerStyle = .continuous
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var materialOverride
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let material = materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency)
        content
            .background(AskGlassBackground(material: material, corner: corner, opaqueFill: opaqueFill,
                                           placement: .inWindow, cornerStyle: cornerStyle))
            .overlay {
                let border = material.idleBorder(AskTheme.border, increasedContrast: contrast == .increased)
                if border != .clear {
                    RoundedRectangle(cornerRadius: corner, style: cornerStyle)
                        .strokeBorder(border)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func askInWindowGlass(corner: CGFloat, opaqueFill: Color = AskTheme.raisedSurface) -> some View {
        modifier(AskInWindowGlass(corner: corner, opaqueFill: opaqueFill))
    }

    /// A pill of the given height: header capsules and the stop button.
    func askInWindowGlassPill(height: CGFloat) -> some View {
        modifier(AskInWindowGlass(corner: height / 2, opaqueFill: AskTheme.raisedSurface, cornerStyle: .circular))
    }
}
