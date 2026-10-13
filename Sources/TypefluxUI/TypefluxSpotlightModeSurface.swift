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
            content.frame(width: diameter, height: diameter)
                .background {
                    // Give every material its own finite circle, independent of the control's
                    // native intrinsic size and accessibility representation.
                    TypefluxGlassContainer(radius: .spotlightInput) {
                        Circle().fill(selected ? TypefluxColor.accent.color : .clear)
                            .frame(width: diameter, height: diameter)
                    }
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .clipShape(Circle())
                .contentShape(Circle())
        }
    }
}
