import SwiftUI

struct InstantVoiceInputSuggestionView: View {
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("settings.instantVoiceInput.suggestion.title"))
                .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(L("settings.instantVoiceInput.suggestion.message")
                    .components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.studioBody(StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                StudioButton(title: L("common.cancel"), systemImage: nil, variant: .secondary, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                StudioButton(
                    title: L("settings.instantVoiceInput.suggestion.enable"),
                    systemImage: nil, variant: .primary, action: onEnable
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 520)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                StudioTheme.modalSurface
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
