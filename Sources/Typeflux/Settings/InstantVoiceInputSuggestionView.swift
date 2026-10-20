import SwiftUI

struct InstantVoiceInputSuggestionView: View {
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.instantVoiceInput.suggestion.title"))
                .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(L("settings.instantVoiceInput.suggestion.message")
                    .components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                StudioButton(
                    title: L("common.cancel"), systemImage: nil, variant: .secondary,
                    isCompact: true, action: onCancel
                )
                    .keyboardShortcut(.cancelAction)
                StudioButton(
                    title: L("settings.instantVoiceInput.suggestion.enable"),
                    systemImage: nil, variant: .primary, isCompact: true, action: onEnable
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                StudioTheme.modalSurface
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
