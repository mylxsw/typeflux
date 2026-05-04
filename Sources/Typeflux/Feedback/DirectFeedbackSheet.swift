import SwiftUI

struct DirectFeedbackSheet: View {
    @Binding var content: String
    @Binding var contact: String
    let isSubmitting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: () -> Void

    @FocusState private var isContentFocused: Bool

    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.mediumLarge) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
                Text(L("feedback.direct.title"))
                    .font(.studioDisplay(20, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Text(L("feedback.direct.subtitle"))
                    .font(.studioBody(13))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                Text(L("feedback.direct.contentLabel"))
                    .font(.studioBody(12, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $content)
                        .font(.studioBody(13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 160)
                        .background(StudioTheme.controlSurface)
                        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                                .stroke(StudioTheme.border.opacity(0.72), lineWidth: 1)
                        }
                        .focused($isContentFocused)

                    if content.isEmpty {
                        Text(L("feedback.direct.contentPlaceholder"))
                            .font(.studioBody(13))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
            }

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                Text(L("feedback.direct.contactLabel"))
                    .font(.studioBody(12, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)

                TextField(L("feedback.direct.contactPlaceholder"), text: $contact)
                    .textFieldStyle(.plain)
                    .font(.studioBody(13))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(StudioTheme.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                            .stroke(StudioTheme.border.opacity(0.72), lineWidth: 1)
                    }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                Button(L("common.cancel"), action: onCancel)
                    .disabled(isSubmitting)

                Button {
                    onSubmit()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(L("feedback.direct.submit"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || trimmedContent.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            isContentFocused = true
        }
    }
}
