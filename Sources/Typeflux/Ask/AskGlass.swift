import AppKit
import SwiftUI

typealias AskGlassMaterial = GlassMaterial
typealias AskGlassPlacement = GlassPlacement

extension GlassMaterial {
    func idleBorder(_ border: Color, increasedContrast: Bool) -> Color {
        drawsOwnEdge && !increasedContrast ? LegacyAskPalette.floatingGlassEdge : border
    }
}

extension EnvironmentValues {
    var askGlassMaterialOverride: GlassMaterial? {
        get { glassMaterialOverride }
        set { glassMaterialOverride = newValue }
    }
}

/// Preserves the old palette at the application boundary.
struct AskGlassBackground: View {
    var material: GlassMaterial
    var corner: CGFloat
    var opaqueFill: Color
    var placement: GlassPlacement = .floating
    var cornerStyle: RoundedCornerStyle = .continuous
    var diffuseLauncher = false

    static func effectiveMaterial(_ material: GlassMaterial, reduceTransparency: Bool,
                                  increasedContrast: Bool) -> GlassMaterial {
        GlassBackground.effectiveMaterial(material, reduceTransparency: reduceTransparency,
                                          increasedContrast: increasedContrast)
    }

    var body: some View {
        GlassBackground(material: material, corner: corner, opaqueFill: opaqueFill,
                        placement: placement, cornerStyle: cornerStyle, diffuseLauncher: diffuseLauncher,
                        contrastBorder: TypefluxColor.separator.color, diffuseTint: LegacyAskPalette.launcherGlassTint)
    }
}

/// A floating glass card: the chips' hover cards and the composer's menus.
/// Glass on macOS 26 and the adaptive popover blur before it; with Reduce Transparency an
/// opaque popover surface with a hairline border.
struct AskGlassCardSurface<Content: View>: View {
    enum Kind { case hoverCard, menu }

    var kind: Kind
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var materialOverride
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.interfaceStyle) private var style
    let content: Content

    init(kind: Kind = .hoverCard, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    /// Menus are concentric with their rows at a 6pt inset; hover cards are tighter.
    static func corner(_ kind: Kind, style: InterfaceStyle) -> CGFloat {
        kind == .menu ? style.ask.menuCorner : style.ask.hoverCardCorner
    }

    var body: some View {
        let corner = Self.corner(kind, style: style)
        let material = materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency,
                                                                    style: style)
        content
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .background(AskGlassBackground(
                material: material,
                corner: corner,
                opaqueFill: TypefluxColor.windowBackground.color,
                placement: .menu
            ))
            .overlay {
                if !material.drawsOwnEdge || contrast == .increased {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(TypefluxColor.separator.color)
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
    var placement: AskGlassPlacement = .inWindow
    var cornerStyle: RoundedCornerStyle = .continuous
    /// The drop shadow it floats on; nil for glass that sits inside another surface.
    var elevation: AskElevation? = .panel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var materialOverride
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.interfaceStyle) private var style

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: cornerStyle) }

    /// Classic surfaces are flat: only what floats above the window keeps a shadow.
    static func elevation(_ elevation: AskElevation?, style: InterfaceStyle) -> AskElevation? {
        style.usesGlass || elevation == .popover ? elevation : nil
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if style.usesGlass {
            glass(content)
        } else {
            classic(content)
        }
    }

    /// A solid fill with a hairline edge; no frost and no rim light.
    private func classic(_ content: Content) -> some View {
        content
            .background(shape.fill(opaqueFill).allowsHitTesting(false))
            .background {
                if let elevation = Self.elevation(elevation, style: style) {
                    AskOuterShadow(shape: shape, elevation: elevation)
                }
            }
            .overlay(shape.strokeBorder(AskClassic.cardBorder).allowsHitTesting(false))
    }

    private func glass(_ content: Content) -> some View {
        let material = AskGlassBackground.effectiveMaterial(
            materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency),
            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased
        )
        return content
            .background(AskGlassBackground(material: material, corner: corner, opaqueFill: opaqueFill,
                                           placement: placement, cornerStyle: cornerStyle))
            .background {
                if let elevation { AskOuterShadow(shape: shape, elevation: elevation) }
            }
            // Always outlined, unlike the launcher: frosted with the window's own
            // colours, the pills and cards would otherwise vanish on a white window.
            .overlay(shape.strokeBorder(TypefluxColor.separator.color).allowsHitTesting(false))
            .overlay {
                // Native glass owns its highlights; draw a rim only for legacy blur.
                if material == .visualEffect {
                    shape.strokeBorder(AskRimLight.gradient(dark: colorScheme == .dark), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
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
    func askInWindowGlass(corner: CGFloat, opaqueFill: Color = LegacyAskPalette.glassFill,
                          elevation: AskElevation? = .panel, placement: AskGlassPlacement = .inWindow) -> some View {
        modifier(AskInWindowGlass(corner: corner, opaqueFill: opaqueFill, placement: placement, elevation: elevation))
    }

    /// A glass pill of the given height around title-row controls. Classic
    /// title rows are flat, so there the controls stand on the row itself.
    func askInWindowGlassPill(height: CGFloat) -> some View {
        modifier(AskInWindowGlassPill(height: height))
    }
}

struct AskInWindowGlassPill: ViewModifier {
    var height: CGFloat
    @Environment(\.interfaceStyle) private var style

    @ViewBuilder
    func body(content: Content) -> some View {
        if style.usesGlass {
            content.modifier(AskInWindowGlass(corner: height / 2, opaqueFill: LegacyAskPalette.glassFill,
                                              cornerStyle: .circular, elevation: .control))
        } else {
            content
        }
    }
}
