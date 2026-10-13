import SwiftUI

/// Password input uses the same native bezel and accessibility naming as other form fields.
public struct TypefluxSecureField: View {
    @Binding private var text: String
    private let title: String

    public init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    public var body: some View {
        SecureField("", text: $text, prompt: Text(title)).textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .labelsHidden().accessibilityLabel(Text(title))
    }
}
