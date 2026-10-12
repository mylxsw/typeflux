import AppKit
import SwiftUI

public struct GlassBackground: View {
    @Environment(\.liquidGlassIntensity) private var intensity
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var material: GlassMaterial
    var corner: CGFloat
    /// Frosts translucent glass and fills the card when transparency is reduced.
    var opaqueFill: Color
    var placement: GlassPlacement = .floating
    /// `.circular` for pills: a continuous corner near half the height draws a
    /// stray sliver at each end of the outline.
    var cornerStyle: RoundedCornerStyle = .continuous
    /// Large launchers use a diffuse backdrop and quieter native optics.
    /// Small popovers and conversation chrome retain the regular glass policy.
    var diffuseLauncher = false

    var contrastBorder: Color
    var diffuseTint: Color

    public init(material: GlassMaterial, corner: CGFloat, opaqueFill: Color,
                placement: GlassPlacement = .floating, cornerStyle: RoundedCornerStyle = .continuous,
                diffuseLauncher: Bool = false, contrastBorder: Color = TypefluxColor.separator.color,
                diffuseTint: Color = TypefluxColor.windowBackground.color) {
        self.material = material
        self.corner = corner
        self.opaqueFill = opaqueFill
        self.placement = placement
        self.cornerStyle = cornerStyle
        self.diffuseLauncher = diffuseLauncher
        self.contrastBorder = contrastBorder
        self.diffuseTint = diffuseTint
    }

    private var usesDiffuseBackdrop: Bool {
        diffuseLauncher
    }

    private var launcherTintOpacity: Double {
        0.48 + intensity.value * 0.30
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: cornerStyle)
    }

    private var effectiveMaterial: GlassMaterial {
        Self.effectiveMaterial(material, reduceTransparency: reduceTransparency,
                               increasedContrast: contrast == .increased)
    }

    public static func effectiveMaterial(_ material: GlassMaterial, reduceTransparency: Bool,
                                         increasedContrast: Bool) -> GlassMaterial {
        reduceTransparency || increasedContrast ? .opaque : material
    }

    public var body: some View {
        ZStack {
            switch effectiveMaterial {
            case .liquidGlass:
                if usesDiffuseBackdrop {
                    diffuseBackdrop
                    liquidGlass.opacity(0.16)
                    shape.fill(diffuseTint.opacity(launcherTintOpacity))
                } else {
                    if placement == .windowEdge, colorScheme == .light {
                        // Keep the edge column's backdrop independent of the canvas.
                        // The native glass above supplies adaptive contrast and optics.
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow,
                                         cornerRadius: corner)
                    }
                    frosting
                    liquidGlass
                    shape.fill(opaqueFill.opacity(intensity.extraTintOpacity))
                }
            case .visualEffect:
                if usesDiffuseBackdrop {
                    diffuseBackdrop
                    shape.fill(diffuseTint.opacity(launcherTintOpacity))
                } else {
                    fallback
                    frosting
                }
            case .opaque:
                shape.fill(opaqueFill)
            }
        }
        .clipShape(shape)
        .overlay {
            // Small floating cards keep a specular edge; the large launcher
            // leaves its outline to the subdued native optics.
            if !usesDiffuseBackdrop, effectiveMaterial == .visualEffect ||
                (effectiveMaterial == .liquidGlass && placement == .floating) {
                rim
            }
            if effectiveMaterial == .opaque, contrast == .increased {
                shape.strokeBorder(contrastBorder, lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var liquidGlass: some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                LiquidGlassView(cornerRadius: corner)
            } else {
                fallback
            }
        #else
            fallback
        #endif
    }

    @ViewBuilder private var frosting: some View {
        let base = placement.frost(dark: colorScheme == .dark, material: effectiveMaterial)
        shape.fill(opaqueFill.opacity(effectiveMaterial == .liquidGlass
                ? intensity.nativeFrostOpacity(base) : intensity.legacyFrostOpacity(base)))
    }

    private var fallback: some View {
        VisualEffectBlur(material: placement.fallbackMaterial, blendingMode: placement.blending,
                         cornerRadius: corner)
    }

    /// System HUD blur spreads backdrop colors without the bright regular-glass
    /// backplate. No fixed gradients or private blur filters are involved.
    private var diffuseBackdrop: some View {
        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: corner)
    }

    /// Bright on the light-facing corner, fading along the edge.
    private var rim: some View {
        shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(colorScheme == .dark ? 0.30 : 0.72), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.7),
                    .init(color: Color.white.opacity(colorScheme == .dark ? 0.10 : 0.24), location: 1)
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
    private struct LiquidGlassView: NSViewRepresentable {
        var cornerRadius: CGFloat

        func makeNSView(context _: Context) -> NSGlassEffectView {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = cornerRadius
            return view
        }

        func updateNSView(_ view: NSGlassEffectView, context _: Context) {
            if view.cornerRadius != cornerRadius {
                view.cornerRadius = cornerRadius
            }
        }
    }
#endif
