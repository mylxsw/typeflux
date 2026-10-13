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
        content
            // Separate AppKit layers keep animated content from recompositing the glass.
            .background(GlassBackground(material: material, corner: radius.value(for: style),
                                        opaqueFill: TypefluxColor.windowBackground.color, placement: placement,
                                        cornerStyle: radius == .spotlightInput ? .circular : .continuous))
            .overlay {
                if material == .opaque, accessibility.increasedContrast, contrast != .increased {
                    shape.strokeBorder(TypefluxColor.separator.color, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}
