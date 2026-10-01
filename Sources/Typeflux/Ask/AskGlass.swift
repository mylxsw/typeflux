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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    var body: some View {
        ZStack {
            switch material {
            case .liquidGlass:
                liquidGlass
            case .visualEffect:
                StudioVisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: corner)
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
                StudioVisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: corner)
            }
        #else
            StudioVisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: corner)
        #endif
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

/// Background for the composer's popovers (model, reasoning). On macOS 26 the
/// system popover is already glass, so an opaque fill would hide it; earlier
/// systems and Reduce Transparency keep the opaque popover surface.
struct AskPopoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func fill(_ material: AskGlassMaterial) -> Color {
        material == .liquidGlass ? .clear : AskTheme.popoverSurface
    }

    func body(content: Content) -> some View {
        content.background(Self.fill(AskGlassMaterial.resolve(reduceTransparency: reduceTransparency)))
    }
}

/// The chips' hover card: a small glass card matching the launcher.
struct AskHoverCardSurface<Content: View>: View {
    static var corner: CGFloat { 14 }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let content: Content

    var body: some View {
        let material = AskGlassMaterial.resolve(reduceTransparency: reduceTransparency)
        content
            .background(AskGlassBackground(material: material, corner: Self.corner, opaqueFill: AskTheme.popoverSurface))
            .overlay {
                if !material.drawsOwnEdge {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(AskTheme.border)
                }
            }
    }
}
