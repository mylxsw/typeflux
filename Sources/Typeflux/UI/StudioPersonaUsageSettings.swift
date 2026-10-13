import SwiftUI

struct StudioPersonaUsageStrip: View {
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                selectionRow(auxiliary: false)
                Divider()
                selectionRow(auxiliary: true)
                Divider()
                TypefluxSettingsRow(L("personas.redesign.apps"), description: appRuleSummary) {
                    Button(L("personas.redesign.manage")) { viewModel.openPersonaAppRules() }
                        .accessibilityIdentifier("personas.appRules")
                }
            }
        }
    }

    private var appRuleSummary: String {
        guard viewModel.personaAppBindingsEnabled else { return L("personas.redesign.allPaused") }
        let count = L("personas.redesign.appCount", viewModel.personaAppBindings.count)
        return viewModel.pausedPersonaAppRuleCount > 0
            ? count + " · " + L("personas.redesign.pausedCount", viewModel.pausedPersonaAppRuleCount) : count
    }

    private func selectionRow(auxiliary: Bool) -> some View {
        TypefluxSettingsRow(L(auxiliary ? "personas.redesign.auxiliary" : "personas.redesign.dictation")) {
            HStack {
                PersonaSelectionMenu(viewModel: viewModel,
                                     selection: auxiliary ? UUID(uuidString: viewModel.auxiliaryPersonaID)
                                         : viewModel.defaultPersonaSelectionID,
                                     allowsNone: !auxiliary, showsSummaries: true) { id in
                    if auxiliary, let id {
                        viewModel.setAuxiliaryPersona(id.uuidString)
                    } else {
                        viewModel.setDefaultPersonaSelection(id)
                    }
                }.accessibilityIdentifier(auxiliary ? "personas.auxiliarySelection" : "personas.defaultSelection")
                    .accessibilityLabel(L(auxiliary ? "personas.redesign.auxiliary" : "personas.redesign.dictation"))
                Button { viewModel.openPersonaShortcutSettings() } label: {
                    Text((auxiliary ? viewModel.auxiliaryHotkey : viewModel.activationHotkey)
                        .map(HotkeyFormat.display) ?? L("personas.redesign.unset")).font(.subheadline)
                }.buttonStyle(.borderless).help(L("personas.redesign.shortcutsHelp"))
            }
        }
    }
}
