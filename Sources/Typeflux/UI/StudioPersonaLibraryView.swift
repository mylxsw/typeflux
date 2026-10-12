import SwiftUI

/// Usage and content remain independent; only the roster and definition scroll.
struct StudioPersonaLibraryView: View {
    @Environment(\.studioWindowWidth) private var windowWidth
    @ObservedObject var viewModel: StudioViewModel
    let onDelete: (PersonaProfile) -> Void

    var body: some View {
        GeometryReader { geometry in
            let narrow = (windowWidth ?? geometry.size.width) < 1000
            VStack(spacing: 16) {
                StudioPersonaUsageStrip(viewModel: viewModel, narrow: narrow)
                    .disabled(viewModel.isPersonaRulesDrawerPresented || viewModel.personaPendingDeletion != nil)
                HStack(spacing: 14) {
                    StudioPersonaRosterView(viewModel: viewModel, onDelete: onDelete)
                        .frame(width: narrow ? 250 : 300)
                    StudioPersonaDetailView(viewModel: viewModel, onDelete: onDelete)
                }
                .frame(maxHeight: .infinity)
                .disabled(viewModel.isPersonaRulesDrawerPresented || viewModel.personaPendingDeletion != nil)
            }
            .overlay {
                if viewModel.isPersonaRulesDrawerPresented {
                    Color.black.opacity(0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.closePersonaAppRules() }
                        .accessibilityLabel(L("personas.redesign.close"))
                        .accessibilityAddTraits(.isButton)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        StudioPersonaAppRulesDrawer(viewModel: viewModel)
                            .frame(width: min(520, geometry.size.width))
                    }
                }
            }
            .overlay {
                if let persona = viewModel.personaPendingDeletion {
                    Color.black.opacity(0.4)
                    PersonaDeletionConfirmationView(viewModel: viewModel, persona: persona)
                        .frame(width: min(440, geometry.size.width - 32))
                }
            }
            .overlay(alignment: .bottom) {
                if let message = viewModel.personaUndoMessage, viewModel.personaPendingDeletion == nil {
                    HStack(spacing: 14) {
                        Text(message).lineLimit(2)
                        Button(L("personas.redesign.undo")) { viewModel.undoPersonaChange() }
                            .accessibilityIdentifier("personas.undoAction")
                            .foregroundStyle(StudioTheme.accent)
                        Button { viewModel.dismissPersonaUndo() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(L("personas.redesign.close"))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(12)
                    .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
                    .shadow(radius: 8, y: 3)
                    .padding(12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("personas.undo")
                }
            }
        }
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

struct PersonaPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(StudioTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.border.opacity(0.65)))
    }
}

extension EnvironmentValues {
    @Entry var studioWindowWidth: CGFloat?
}
