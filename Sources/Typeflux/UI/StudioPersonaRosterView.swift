import SwiftUI

struct StudioPersonaRosterView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onDelete: (PersonaProfile) -> Void

    /// Generated personas start with a localized "Candidate:" label that is shown dimmed.
    static let candidatePrefixes = ["候选：", "候選：", "Candidate:", "候補：", "후보:"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("personas.redesign.library")).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TFColors.textPrimary)
                Text("\(viewModel.personas.count)").font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(TFColors.textTertiary)
                Spacer(minLength: 0)
                TFButton(title: L("personas.redesign.new"), systemImage: "plus", size: .small) {
                    viewModel.beginCreatingPersona()
                }
                .accessibilityIdentifier("personas.create")
            }
            .padding(.horizontal, 4)
            TFSearchField(placeholder: L("studio.search.personas"), text: $viewModel.searchQuery,
                          placement: .container, resultCount: viewModel.filteredPersonas.count,
                          identifier: "personas.search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.isCreatingPersonaDraft {
                        section(L("personas.redesign.creating"), count: 1) {
                            TFSourceRow(
                                title: viewModel.personaDraftName.isEmpty ? L("personas.redesign.new")
                                    : viewModel.personaDraftName,
                                isSelected: true, showsChangeDot: viewModel.hasPersonaDraftChanges
                            ) {}
                        }
                    }
                    group(title: L("settings.personas.custom"), personas: viewModel.filteredCustomPersonas)
                    group(title: L("personas.redesign.builtIn"), personas: viewModel.filteredBuiltInPersonas)
                    if viewModel.filteredPersonas.isEmpty, !viewModel.searchQuery.isEmpty {
                        VStack(spacing: 10) {
                            TFFootnote(text: L("personas.redesign.noResults", viewModel.searchQuery))
                            TFButton(title: L("personas.redesign.createSearch", viewModel.searchQuery), kind: .link) {
                                viewModel.beginCreatingPersona(
                                    name: viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            .accessibilityIdentifier("personas.createFromSearch")
                        }
                        .padding(.vertical, 24).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .tfCardSurface()
    }

    private func section(_ title: String, count: Int, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TFSectionHeader(title: title, count: count)
            rows()
        }
    }

    @ViewBuilder private func group(title: String, personas: [PersonaProfile]) -> some View {
        if !personas.isEmpty {
            section(title, count: personas.count) {
                ForEach(personas) { persona in
                    TFSourceRow(
                        title: persona.name,
                        dimmedPrefix: Self.candidatePrefixes.first(where: persona.name.hasPrefix),
                        query: viewModel.searchQuery,
                        isSelected: !viewModel.isCreatingPersonaDraft && viewModel.selectedPersonaID == persona.id,
                        showsChangeDot: viewModel.selectedPersonaID == persona.id && viewModel.hasPersonaDraftChanges
                    ) {
                        viewModel.selectPersonaGuardingDraft(persona.id)
                    }
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
}
