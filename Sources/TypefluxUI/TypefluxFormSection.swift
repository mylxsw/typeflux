import SwiftUI

public struct TypefluxFormSection<Content: View>: View {
    private let title: String
    private let footer: String?
    private let content: Content

    public init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        Section { content } header: {
            Text(title).font(.headline)
        } footer: {
            if let footer { Text(footer).font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color) }
        }
    }
}
