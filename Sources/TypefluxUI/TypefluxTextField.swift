import SwiftUI

public struct TypefluxTextField: View {
    @Environment(\.interfaceStyle) private var style
    @Binding private var text: String
    private let title: String
    private let prompt: String?
    private let error: String?

    public init(_ title: String, text: Binding<String>, prompt: String? = nil, error: String? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.error = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .textFieldStyle(.roundedBorder)
                .overlay {
                    if let error, !error.isEmpty {
                        RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: style))
                            .stroke(TypefluxColor.danger.color)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(error ?? ""))
            if let error, !error.isEmpty { Text(error).font(.subheadline).foregroundStyle(TypefluxColor.danger.color) }
        }
    }
}
