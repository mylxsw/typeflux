import SwiftUI

/// Native list selection guards unsaved drafts; each pane owns its scrolling.
struct StudioPersonaLibraryView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onDelete: (PersonaProfile) -> Void

    var body: some View {
        HSplitView {
            StudioPersonaRosterView(viewModel: viewModel, onDelete: onDelete)
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
            StudioPersonaDetailView(viewModel: viewModel, onDelete: onDelete)
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isPersonaRulesDrawerPresented },
            set: {
                if !$0 {
                    viewModel.closePersonaAppRules()
                }
            }
        )) { StudioPersonaAppRulesDrawer(viewModel: viewModel) }
        .confirmationDialog(L("settings.personas.deleteDialog.title"), isPresented: Binding(
            get: { viewModel.personaPendingDeletion != nil },
            set: {
                if !$0 {
                    viewModel.personaPendingDeletion = nil
                }
            }
        ), titleVisibility: .visible, presenting: viewModel.personaPendingDeletion) { persona in
            Button(L("common.delete"), role: .destructive) {
                viewModel.deletePersona(id: persona.id)
                viewModel.personaPendingDeletion = nil
            }.accessibilityIdentifier("personas.confirmDelete")
            Button(L("common.cancel"), role: .cancel) { viewModel.personaPendingDeletion = nil }
        } message: { persona in Text(viewModel.personaDeletionMessage(for: persona)) }
        .onAppear {
            if viewModel.selectedPersonaID == nil, !viewModel.isCreatingPersonaDraft {
                viewModel.selectPersona(SettingsStore.defaultPersonaID)
            }
        }
        .onExitCommand {
            if viewModel.personaPendingDeletion != nil {
                viewModel.personaPendingDeletion = nil
            } else if viewModel.isPersonaRulesDrawerPresented {
                viewModel.closePersonaAppRules()
            }
        }
        .alert(L("personas.redesign.guardTitle", viewModel.personaDraftName), isPresented: Binding(
            get: { viewModel.pendingPersonaNavigation != nil },
            set: {
                if !$0 {
                    viewModel.resolvePersonaDraftGuard(.cancel)
                }
            }
        )) {
            Button(L("personas.redesign.discard"), role: .destructive) { viewModel.resolvePersonaDraftGuard(.discard) }
                .accessibilityIdentifier("personas.guard.discard")
            Button(L("common.cancel"), role: .cancel) { viewModel.resolvePersonaDraftGuard(.cancel) }
                .accessibilityIdentifier("personas.guard.cancel")
            Button(L("personas.redesign.save")) { viewModel.resolvePersonaDraftGuard(.save) }
                .accessibilityIdentifier("personas.guard.save")
                .disabled(!viewModel.canSavePersonaDraft)
        } message: {
            Text(L("personas.redesign.guardMessage"))
        }
    }
}

extension EnvironmentValues {
    @Entry var studioWindowWidth: CGFloat?
}
