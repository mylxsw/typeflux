import SwiftUI

public struct TypefluxSettingsRow<Control: View>: View {
    private let title: String
    private let description: String?
    private let control: Control

    public init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    public var body: some View {
        LabeledContent {
            control
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                if let description {
                    Text(description).font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            }
        }
        // A form row can contain several independently operable controls, such as a
        // secure field and its reveal button. Keep each control in the AX tree.
        .accessibilityElement(children: .contain)
    }
}
