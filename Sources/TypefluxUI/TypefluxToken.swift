import SwiftUI

public struct TypefluxToken: View {
    private let title: String
    private let removeLabel: String
    private let onRemove: (() -> Void)?
    private let systemImage: String?
    private let action: (() -> Void)?

    public init(_ title: String, removeLabel: String, systemImage: String? = nil,
                action: (() -> Void)? = nil, onRemove: (() -> Void)? = nil) {
        self.title = title
        self.removeLabel = removeLabel
        self.onRemove = onRemove
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let action {
                TypefluxButton(kind: .borderless, action: action) { label }
                    .accessibilityLabel(title)
            } else {
                label
            }
            if let onRemove { TypefluxIconButton(removeLabel, systemImage: "xmark", size: .mini, action: onRemove) }
        }
        .modifier(TypefluxTokenSurface())
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1)
        }.font(.body)
    }
}
