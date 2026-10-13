import SwiftUI

/// A rich editor can share the clipboard's capsule and independent mode surfaces.
public struct TypefluxSpotlightHeader<Input: View, Modes: View>: View {
    @Environment(\.interfaceStyle) private var style
    private let input: Input
    private let modes: Modes

    public init(@ViewBuilder input: () -> Input, @ViewBuilder modes: () -> Modes) {
        self.input = input()
        self.modes = modes()
    }

    public var body: some View {
        HStack(spacing: TypefluxSpacing.small.value(for: style)) {
            if style == .classic {
                input.frame(maxWidth: .infinity)
            } else {
                TypefluxGlassContainer(radius: .spotlightInput) {
                    input.frame(maxWidth: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightInput.value(for: style),
                                            style: .circular))
            }
            modes.fixedSize(horizontal: true, vertical: true)
        }
        .frame(minHeight: TypefluxControlHeight.spotlightInput.value(for: style))
    }
}
