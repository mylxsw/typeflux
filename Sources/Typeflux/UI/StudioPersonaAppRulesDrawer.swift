import AppKit
import SwiftUI

struct StudioPersonaAppRulesDrawer: View {
    @ObservedObject var viewModel: StudioViewModel
    @State private var scope: PersonaAppPickerScope = .running
    @State private var search = ""
    @State private var candidates: [PersonaAppCandidate] = []
    @State private var loading = false

    private var filteredCandidates: [PersonaAppCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter {
            (scope == .all || $0.isRunning)
                && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                    || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("settings.personaAppBindings.title")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { viewModel.closePersonaAppRules() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L("personas.redesign.close"))
                    .accessibilityIdentifier("personas.closeRules")
            }
            Toggle(L("personas.redesign.enableRules"), isOn: Binding(
                get: { viewModel.personaAppBindingsEnabled }, set: viewModel.setPersonaAppBindingsEnabled
            ))
            .toggleStyle(.switch)
            .accessibilityIdentifier("personas.rulesEnabled")
            .padding(12)
            .background(StudioTheme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.personaAppBindings.isEmpty {
                        Text(L("settings.personaAppBindings.empty")).foregroundStyle(StudioTheme.textSecondary).padding(
                            .vertical,
                            16
                        )
                    }
                    VStack(spacing: 0) {
                        ForEach(viewModel.personaAppBindings) { binding in
                            rule(binding)
                            if binding.id != viewModel.personaAppBindings.last?.id {
                                Divider()
                            }
                        }
                    }
                    Button { viewModel.openPersonaAppRules(adding: true) } label: {
                        Label(L("settings.personaAppBindings.add"), systemImage: "plus")
                    }
                    .buttonStyle(.plain).foregroundStyle(StudioTheme.accent)
                    .padding(.vertical, 6)
                    if viewModel.isAddingPersonaAppRule {
                        addFlow
                    }
                }
                .padding(1)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(StudioTheme.border).frame(width: 1) }
        .shadow(color: .black.opacity(0.2), radius: 16, x: -6)
        .task {
            loading = true
            let apps = await PersonaAppDiscovery.discoverPersonaAppCandidates(scope: .all)
            guard !Task.isCancelled else { return }
            candidates = apps
            loading = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personas.rulesDrawer")
    }

    private func rule(_ binding: PersonaAppBinding) -> some View {
        let candidate = candidates
            .first {
                PersonaAppBinding.normalize($0.preferredIdentifier) == PersonaAppBinding
                    .normalize(binding.appIdentifier)
            }
        return HStack(spacing: 9) {
            PersonaAppIcon(identifier: binding.appIdentifier, url: candidate?.appURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate?.displayName ?? binding.appIdentifier).fontWeight(.medium).lineLimit(1)
                Text(binding.appIdentifier).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(binding.isEnabled ? 1 : 0.5)
            .help(binding.appIdentifier)
            PersonaSelectionMenu(viewModel: viewModel, selection: binding.personaID) {
                viewModel.updatePersonaAppBindingPersona(id: binding.id, personaID: $0)
            }
            .frame(width: 180)
            .opacity(binding.isEnabled ? 1 : 0.5)
            Toggle(L("settings.personaAppBindings.binding.enable"), isOn: Binding(
                get: { binding.isEnabled },
                set: { viewModel.setPersonaAppBindingEnabled(id: binding.id, isEnabled: $0) }
            ))
            .labelsHidden().toggleStyle(.switch)
            .accessibilityLabel(L("settings.personaAppBindings.binding.enable") + " " + binding.appIdentifier)
            Button { viewModel.removePersonaAppBinding(id: binding.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .accessibilityLabel(L("common.delete") + " " + binding.appIdentifier)
        }
        .padding(.vertical, 10).padding(.horizontal, 4)
        .opacity(viewModel.personaAppBindingsEnabled ? 1 : 0.5)
    }

    private var addFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.personaAppBindings.addTitle")).fontWeight(.semibold)
                Spacer()
                Button(L("common.cancel")) { viewModel.isAddingPersonaAppRule = false }
                    .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary)
            }
            PersonaSelectionMenu(viewModel: viewModel, selection: viewModel.personaAppBindingDraftPersonaID) {
                viewModel.personaAppBindingDraftPersonaID = $0
            }
            Picker(L("settings.personaAppBindings.picker.title"), selection: $scope) {
                ForEach(PersonaAppPickerScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField(L("settings.personaAppBindings.picker.searchPlaceholder"), text: $search)
                .textFieldStyle(.roundedBorder)
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if filteredCandidates.isEmpty {
                Text(L("settings.personaAppBindings.picker.empty")).foregroundStyle(StudioTheme.textSecondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredCandidates) { candidate in candidateRow(candidate) }
                    }
                }
                .frame(height: 180)
            }
            Divider()
            Text(L("personas.redesign.manualApp")).foregroundStyle(StudioTheme.textSecondary)
            HStack {
                TextField(
                    L("settings.personaAppBindings.appIdentifierPlaceholder"),
                    text: $viewModel.personaAppBindingDraftIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.savePersonaAppBinding() }
                Button(L("settings.personaAppBindings.add")) { viewModel.savePersonaAppBinding() }
                    .disabled(!viewModel.canSavePersonaAppBinding)
            }
            if viewModel.hasPersonaAppRule(viewModel.personaAppBindingDraftIdentifier) {
                Text(L("personas.redesign.existingRule")).foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .padding(12)
        .background(StudioTheme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
    }

    private func candidateRow(_ candidate: PersonaAppCandidate) -> some View {
        let exists = viewModel.hasPersonaAppRule(for: candidate)
        return Button {
            viewModel.personaAppBindingDraftIdentifier = candidate.preferredIdentifier
            viewModel.savePersonaAppBinding()
        } label: {
            HStack(spacing: 8) {
                PersonaAppIcon(identifier: candidate.preferredIdentifier, url: candidate.appURL, size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.displayName).lineLimit(1)
                    Text(candidate.bundleIdentifier ?? candidate.preferredIdentifier)
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if exists {
                    Text(L("personas.redesign.existingRule")).font(.system(size: 10))
                } else if candidate.isRunning {
                    Text(L("settings.personaAppBindings.picker.runningBadge")).font(.system(size: 10))
                        .foregroundStyle(StudioTheme.success)
                }
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(exists).opacity(exists ? 0.4 : 1)
    }
}
