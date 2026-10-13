import SwiftUI

struct PersonaSelectionMenu: View {
    @ObservedObject var viewModel: StudioViewModel
    let selection: UUID?
    var allowsNone = true
    var showsSummaries = false
    let onSelect: (UUID?) -> Void

    private var noneTitle: String {
        L(showsSummaries ? "personas.redesign.none" : "personas.redesign.noneShort")
    }

    var body: some View {
        TypefluxPopup(L("settings.personas.name"), selection: Binding(get: { selection }, set: onSelect),
                      borderless: true) {
            if allowsNone {
                Text(noneTitle).tag(UUID?.none).accessibilityIdentifier("personas.pick.none")
            }
            if let selection, !viewModel.personas.contains(where: { $0.id == selection }) {
                Text(viewModel.personaTitle(selection)).tag(Optional(selection))
            }
            group(L("settings.personas.custom"), personas: viewModel.personas.filter { !$0.isSystem })
            group(L("personas.redesign.builtIn"), personas: viewModel.personas.filter(\.isSystem))
        }
    }

    private func group(_ title: String, personas: [PersonaProfile]) -> some View {
        Section(title) {
            ForEach(personas) { persona in
                Text(persona.name).tag(Optional(persona.id))
                    .accessibilityIdentifier("personas.pick." + persona.id.uuidString)
            }
        }
    }
}
