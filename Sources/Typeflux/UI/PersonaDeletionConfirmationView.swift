import AppKit
import SwiftUI

struct PersonaDeletionConfirmationView: View {
    @ObservedObject var viewModel: StudioViewModel
    let persona: PersonaProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.personas.deleteDialog.title"))
                .font(.system(size: 17, weight: .semibold))
            Text(viewModel.personaDeletionMessage(for: persona))
                .font(.system(size: 13)).lineSpacing(5)
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("common.cancel")) { viewModel.personaPendingDeletion = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("common.delete"), role: .destructive) {
                    viewModel.deletePersona(id: persona.id)
                    viewModel.personaPendingDeletion = nil
                }
                .accessibilityIdentifier("personas.confirmDelete")
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.border))
        .shadow(radius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personas.deleteConfirmation")
    }
}
