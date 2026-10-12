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
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: SettingsControlMetrics.fontSize))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 96, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("models.form.label.\(title)")
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("models.form.field.\(title)")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}
