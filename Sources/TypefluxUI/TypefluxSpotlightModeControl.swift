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
            TypefluxGlassContainer(radius: .spotlightInput, placement: placement) {
                content
                    .frame(width: TypefluxControlHeight.spotlightModeButton.value(for: style),
                           height: TypefluxControlHeight.spotlightModeButton.value(for: style))
                    .contentShape(Circle())
            }
        }
    }
}
