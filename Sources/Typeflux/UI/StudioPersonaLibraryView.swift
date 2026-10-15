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
                    HStack(spacing: TFMetrics.toolbarSpacing) {
                        Text(message).font(.system(size: 12.5)).foregroundStyle(TFColors.textPrimary).lineLimit(2)
                        Spacer(minLength: 8)
                        TFButton(title: L("personas.redesign.undo"), size: .small) { viewModel.undoPersonaChange() }
                            .accessibilityIdentifier("personas.undoAction")
                        TFButton(title: L("personas.redesign.close"), systemImage: "xmark", kind: .plain, size: .small,
                                 iconOnly: true) { viewModel.dismissPersonaUndo() }
                    }
                    .padding(.horizontal, 12).frame(minHeight: 40)
                    .frame(maxWidth: 520)
                    .tfCardSurface()
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
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

extension EnvironmentValues {
    @Entry var studioWindowWidth: CGFloat?
}
