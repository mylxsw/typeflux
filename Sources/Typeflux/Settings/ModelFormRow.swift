import SwiftUI

/// The same label column and field spacing for speech and language provider connections.
struct ModelFormRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        TFLabeledField(label: title, labelIdentifier: "models.form.label.\(title)") {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("models.form.field.\(title)")
        }
    }
}
