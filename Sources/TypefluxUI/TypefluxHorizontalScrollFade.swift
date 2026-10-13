import SwiftUI

/// Fade only the inset at either edge, keeping complete scrollable tokens readable.
public struct TypefluxHorizontalScrollFade: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    public init() {}

    public func body(content: Content) -> some View {
        content.mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(width: TypefluxSpacing.small.value(for: style))
                Rectangle().fill(.white)
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: TypefluxSpacing.small.value(for: style))
            }
        }
    }
}
