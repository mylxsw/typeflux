import SwiftUI

/// Navigation surfaces only. All accessibility and Classic overrides remain opaque.
public struct TypefluxGlassContainer<Content: View>: View {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.glassMaterialOverride) private var materialOverride
    @Environment(\.typefluxAccessibilityOptions) private var accessibility
    private let radius: TypefluxRadius
    private let placement: GlassPlacement
    private let content: Content

    public init(radius: TypefluxRadius = .popover, placement: GlassPlacement = .floating,
                @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.placement = placement
        self.content = content()
    }

    private var material: GlassMaterial {
        let resolved = GlassMaterial.resolve(reduceTransparency: reduceTransparency || accessibility.reduceTransparency,
                                             style: style,
                                             increasedContrast: contrast == .increased || accessibility
                                                 .increasedContrast)
        return resolved == .opaque ? .opaque : (materialOverride ?? resolved)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius.value(for: style),
                                     style: radius == .spotlightInput ? .circular : .continuous)
        switch material {
        case .liquidGlass:
            nativeGlass(shape: shape)
        case .visualEffect:
            content.background(VisualEffectBlur(material: placement.fallbackMaterial,
                                                blendingMode: placement.blending,
                                                cornerRadius: radius.value(for: style)))
        case .opaque:
            content.background(TypefluxColor.windowBackground.color, in: shape)
                .overlay {
                    if contrast == .increased || accessibility.increasedContrast {
                        shape.strokeBorder(TypefluxColor.separator.color, lineWidth: 1).allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder private func nativeGlass(shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(VisualEffectBlur(material: placement.fallbackMaterial,
                                                    blendingMode: placement.blending,
                                                    cornerRadius: radius.value(for: style)))
            }
        #else
            content.background(VisualEffectBlur(material: placement.fallbackMaterial,
                                                blendingMode: placement.blending,
                                                cornerRadius: radius.value(for: style)))
        #endif
    }
}
