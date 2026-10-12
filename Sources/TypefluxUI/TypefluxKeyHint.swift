import SwiftUI

public struct TypefluxKeyHint: View {
    private let keys: String
    private let accessibilityLabel: String

    public init(_ keys: String, accessibilityLabel: String) {
        self.keys = keys
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        Text(keys).font(.callout).monospaced().foregroundStyle(TypefluxColor.secondaryLabel.color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(TypefluxColor.controlBackground.color, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(TypefluxColor.separator.color))
            .accessibilityLabel(Text(accessibilityLabel))
    }
}
