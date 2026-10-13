import SwiftUI

/// Circular glass in Tahoe, an inline borderless control in Classic.
public struct TypefluxSpotlightModeControl<Content: View>: View {
    @Environment(\.interfaceStyle) private var style
    private let placement: GlassPlacement
    private let content: Content

    public init(placement: GlassPlacement = .floating, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }

    public var body: some View {
        if style == .classic {
            content
        } else {
            ZStack { content }
                .frame(width: TypefluxControlHeight.spotlightModeButton.value(for: style),
                       height: TypefluxControlHeight.spotlightModeButton.value(for: style))
                .background {
                    TypefluxGlassContainer(radius: .spotlightInput, placement: placement) { Color.clear }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .contain)
        }
    }
}
