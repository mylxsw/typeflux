import SwiftUI

/// Native label and control layout shared by provider forms.
struct ModelFormRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        TypefluxSettingsRow(title) {
            content.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("models.form.field.\(title)")
        }.accessibilityIdentifier("models.form.row.\(title)")
    }
}
