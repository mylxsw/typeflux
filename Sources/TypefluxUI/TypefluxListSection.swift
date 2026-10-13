import SwiftUI

/// Eager grouped list content keeps row actions separate from the disclosure button.
public struct TypefluxListSection<Content: View>: View {
    @Binding private var isExpanded: Bool
    private let title: String
    private let count: Int
    private let identifier: String
    private let expandedValue: String
    private let collapsedValue: String
    private let content: Content

    public init(_ title: String, count: Int, isExpanded: Binding<Bool>, identifier: String,
                expandedValue: String, collapsedValue: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        _isExpanded = isExpanded
        self.identifier = identifier
        self.expandedValue = expandedValue
        self.collapsedValue = collapsedValue
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).accessibilityHidden(true)
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                    Text(count.formatted()).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isExpanded ? expandedValue : collapsedValue))
            .accessibilityIdentifier(identifier)
            if isExpanded {
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
