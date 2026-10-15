import AppKit
import SwiftUI

struct PersonaDeletionConfirmationView: View {
    @ObservedObject var viewModel: StudioViewModel
    let persona: PersonaProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("settings.personas.deleteDialog.title"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
            Text(viewModel.personaDeletionMessage(for: persona))
                .font(.system(size: 13)).lineSpacing(4)
                .foregroundStyle(TFColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TFMetrics.toolbarSpacing) {
                Spacer()
                TFButton(title: L("common.cancel")) { viewModel.personaPendingDeletion = nil }
                    .keyboardShortcut(.cancelAction)
                TFButton(title: L("common.delete"), kind: .primary, destructive: true) {
                    viewModel.deletePersona(id: persona.id)
                    viewModel.personaPendingDeletion = nil
                }
                .accessibilityIdentifier("personas.confirmDelete")
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: TFMetrics.sheetCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TFMetrics.sheetCornerRadius, style: .continuous)
            .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
        .shadow(radius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personas.deleteConfirmation")
    }
}
