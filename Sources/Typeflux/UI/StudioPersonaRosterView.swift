import SwiftUI

struct StudioPersonaRosterView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onDelete: (PersonaProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("personas.redesign.library")).fontWeight(.semibold)
                Text("\(viewModel.personas.count)").foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 0)
                Button { viewModel.beginCreatingPersona() } label: {
                    Label(L("personas.redesign.new"), systemImage: "plus")
                }
                .buttonStyle(.plain).font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioTheme.border))
                .accessibilityIdentifier("personas.create")
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.isCreatingPersonaDraft {
                        heading(L("personas.redesign.creating"), count: 1)
                        row(
                            title: viewModel.personaDraftName.isEmpty ? L("personas.redesign.new") : viewModel
                                .personaDraftName,
                            selected: true,
                            dirty: viewModel.hasPersonaDraftChanges
                        ) {}
                    }
                    group(title: L("settings.personas.custom"), personas: viewModel.filteredCustomPersonas)
                    group(title: L("personas.redesign.builtIn"), personas: viewModel.filteredBuiltInPersonas)
                    if viewModel.filteredPersonas.isEmpty, !viewModel.searchQuery.isEmpty {
                        VStack(spacing: 12) {
                            Text(L("personas.redesign.noResults", viewModel.searchQuery))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Button(L("personas.redesign.createSearch", viewModel.searchQuery)) {
                                viewModel
                                    .beginCreatingPersona(name: viewModel.searchQuery
                                        .trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            .buttonStyle(.plain).foregroundStyle(StudioTheme.accent)
                            .accessibilityIdentifier("personas.createFromSearch")
                        }
                        .font(.system(size: 12)).padding(.vertical, 25).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(11)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(PersonaPanelModifier())
    }

    @ViewBuilder private func group(title: String, personas: [PersonaProfile]) -> some View {
        if !personas.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                heading(title, count: personas.count).padding(.bottom, 5)
                ForEach(personas) { persona in
                    row(
                        title: persona.name,
                        selected: !viewModel.isCreatingPersonaDraft && viewModel.selectedPersonaID == persona.id,
                        dirty: viewModel.selectedPersonaID == persona.id && viewModel.hasPersonaDraftChanges
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

    private func heading(_ title: String, count: Int) -> some View {
        HStack { Text(title); Spacer(); Text("\(count)") }
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary).padding(.horizontal, 8)
    }

    private func row(title: String, selected: Bool, dirty: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                deEmphasizedName(title, selected: selected).lineLimit(1)
                if dirty {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                selected ? StudioTheme.accent.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title)
        .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func deEmphasizedName(_ title: String, selected: Bool) -> Text {
        let prefixes = ["候选：", "候選：", "Candidate:", "候補：", "후보:"]
        if let prefix = prefixes.first(where: title.hasPrefix) {
            return Text(prefix).foregroundColor(selected ? StudioTheme.accent.opacity(0.7) : StudioTheme.textSecondary)
                + Text(String(title.dropFirst(prefix.count)))
                .foregroundColor(selected ? StudioTheme.accent : StudioTheme.textPrimary)
        }
        return Text(title).foregroundColor(selected ? StudioTheme.accent : StudioTheme.textPrimary)
    }
}
