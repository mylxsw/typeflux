import SwiftUI

struct StudioPersonaRosterView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onDelete: (PersonaProfile) -> Void

    private var selection: Binding<UUID?> {
        Binding(get: {
            viewModel.isCreatingPersonaDraft ? viewModel.personaDraftCreationID : viewModel.selectedPersonaID
        }, set: { id in
            guard let id, id != viewModel.personaDraftCreationID else { return }
            viewModel.selectPersonaGuardingDraft(id)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("personas.redesign.library")).font(.headline)
                Text("\(viewModel.personas.count)").foregroundStyle(.secondary)
                Spacer()
                TypefluxIconButton(L("personas.redesign.new"), systemImage: "plus") {
                    viewModel.beginCreatingPersona()
                }.accessibilityIdentifier("personas.create")
            }.padding(8)
            List(selection: selection) {
                if viewModel.isCreatingPersonaDraft {
                    Section(L("personas.redesign.creating")) {
                        name(
                            viewModel.personaDraftName.isEmpty ? L("personas.redesign.new") : viewModel
                                .personaDraftName,
                            dirty: viewModel.hasPersonaDraftChanges
                        ).tag(viewModel.personaDraftCreationID)
                    }
                }
                group(title: L("settings.personas.custom"), personas: viewModel.filteredCustomPersonas)
                group(title: L("personas.redesign.builtIn"), personas: viewModel.filteredBuiltInPersonas)
            }.listStyle(.inset)
                .overlay {
                    if viewModel.filteredPersonas.isEmpty, !viewModel.searchQuery.isEmpty,
                       !viewModel.isCreatingPersonaDraft {
                        TypefluxEmptyState(L("personas.redesign.noResults", viewModel.searchQuery),
                                           systemImage: "magnifyingglass", description: "") {
                            Button(L("personas.redesign.createSearch", viewModel.searchQuery)) {
                                viewModel.beginCreatingPersona(name: viewModel.searchQuery
                                    .trimmingCharacters(in: .whitespacesAndNewlines))
                            }.accessibilityIdentifier("personas.createFromSearch")
                        }
                    }
                }
        }
    }

    @ViewBuilder private func group(title: String, personas: [PersonaProfile]) -> some View {
        if !personas.isEmpty {
            Section(title + " · \(personas.count)") {
                ForEach(personas) { persona in
                    name(
                        persona.name,
                        dirty: viewModel.selectedPersonaID == persona.id && viewModel.hasPersonaDraftChanges
                    )
                    .tag(persona.id)
                    .contextMenu {
                        Button(L("personas.redesign.duplicate")) { viewModel.duplicatePersona(persona) }
                        if !persona.isSystem {
                            Button(L("personas.redesign.delete"), role: .destructive) { onDelete(persona) }
                        }
                    }
                }
            }
        }
    }

    private func name(_ title: String, dirty: Bool) -> some View {
        HStack {
            Text(title).font(.body).lineLimit(1)
            if dirty {
                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(L("imagegen.unsaved"))
            }
        }.help(title)
    }
}
