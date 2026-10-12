import SwiftUI

public struct TypefluxToken: View {
    @Environment(\.interfaceStyle) private var style
    private let title: String
    private let removeLabel: String
    private let onRemove: (() -> Void)?

    public init(_ title: String, removeLabel: String, onRemove: (() -> Void)? = nil) {
        self.title = title
        self.removeLabel = removeLabel
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.body)
            if let onRemove { TypefluxIconButton(removeLabel, systemImage: "xmark", size: .mini, action: onRemove) }
        }
        .padding(.leading, 8).padding(.trailing, onRemove == nil ? 8 : 4).padding(.vertical, 2)
        .background(TypefluxColor.accent.color.opacity(0.12))
        .background(TypefluxColor.controlBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: style == .classic ? 4 : 99))
        .accessibilityElement(children: .contain)
    }
}
