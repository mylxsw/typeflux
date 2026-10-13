import SwiftUI

/// Shared token chrome also supports rich attachment labels with thumbnails and metadata.
public struct TypefluxTokenSurface: ViewModifier {
    @Environment(\.interfaceStyle) private var style

    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(TypefluxColor.accent.color.opacity(0.12))
            .background(TypefluxColor.controlBackground.color)
            .clipShape(RoundedRectangle(cornerRadius: style == .classic ? 4 : 99))
    }
}
