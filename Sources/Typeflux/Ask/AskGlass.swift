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
                shape.fill(Color.clear).glassEffect(.regular, in: shape)
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
