import SwiftUI

/// Bound the entire control, including its material, so selection cannot change its size.
public struct TypefluxSpotlightModeSurface<Content: View>: View {
    @Environment(\.interfaceStyle) private var style
    private let selected: Bool
    private let content: Content

    public init(selected: Bool = false, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.content = content()
    }

    public var body: some View {
        if style == .classic {
            content
                .background(selected ? TypefluxColor.accent.color.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: TypefluxRadius.button.value(for: style)))
        } else {
            let diameter = TypefluxControlHeight.spotlightModeButton.value(for: style)
            TypefluxGlassContainer(radius: .spotlightInput) {
                content.frame(width: diameter, height: diameter)
                    .background {
                        Circle().fill(selected ? TypefluxColor.accent.color : .clear)
                            .frame(width: diameter, height: diameter)
                            .accessibilityHidden(true)
                    }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .contentShape(Circle())
        }
    }
}
