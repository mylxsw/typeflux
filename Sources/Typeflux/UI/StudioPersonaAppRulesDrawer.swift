import AppKit
import SwiftUI

struct StudioPersonaAppRulesDrawer: View {
    @ObservedObject var viewModel: StudioViewModel
    var discover: () async -> [PersonaAppCandidate] = {
        await PersonaAppDiscovery.discoverPersonaAppCandidates(scope: .all)
    }

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
        TypefluxSheet(title: L("settings.personaAppBindings.title"), cancelTitle: L("common.cancel"),
                      confirmTitle: L("common.done"), confirmIdentifier: "personas.closeRules",
                      cancel: { viewModel.closePersonaAppRules() }, confirm: { viewModel.closePersonaAppRules() },
                      content: {
                          VStack(alignment: .leading, spacing: 12) {
                              Toggle(L("personas.redesign.enableRules"), isOn: Binding(
                                  get: { viewModel.personaAppBindingsEnabled },
                                  set: viewModel.setPersonaAppBindingsEnabled
                              )).toggleStyle(.switch).accessibilityIdentifier("personas.rulesEnabled")
                              TypefluxForm {
                                  Section {
                                      if viewModel.personaAppBindings.isEmpty {
                                          TypefluxEmptyState(
                                              L("settings.personaAppBindings.empty"),
                                              systemImage: "app",
                                              description: ""
                                          )
                                      }
                                      ForEach(viewModel.personaAppBindings) { rule($0) }
                                      Button { viewModel.openPersonaAppRules(adding: true) } label: {
                                          Label(L("settings.personaAppBindings.add"), systemImage: "plus")
                                      }
                                  }
                                  if viewModel.isAddingPersonaAppRule {
                                      Section { addFlow }
                                  }
                              }.frame(height: 460)
                          }
                      }).frame(width: 640)
            .task {
                loading = true
                let apps = await discover()
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
                Text(binding.appIdentifier).font(.subheadline).foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(binding.isEnabled ? 1 : 0.5)
            .help(binding.appIdentifier)
            PersonaSelectionMenu(viewModel: viewModel, selection: binding.personaID) {
                viewModel.updatePersonaAppBindingPersona(id: binding.id, personaID: $0)
            }
            .frame(maxWidth: 180)
            .opacity(binding.isEnabled ? 1 : 0.5)
            Toggle(L("settings.personaAppBindings.binding.enable"), isOn: Binding(
                get: { binding.isEnabled },
                set: { viewModel.setPersonaAppBindingEnabled(id: binding.id, isEnabled: $0) }
            ))
            .labelsHidden().toggleStyle(.switch)
            .accessibilityLabel(L("settings.personaAppBindings.binding.enable") + " " + binding.appIdentifier)
            TypefluxIconButton(L("common.delete") + " " + binding.appIdentifier, systemImage: "trash",
                               kind: .destructive) {
                viewModel.removePersonaAppBinding(id: binding.id)
            }
        }
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
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel(L("settings.personaAppBindings.picker.title"))
            TextField(L("settings.personaAppBindings.picker.searchPlaceholder"), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L("settings.personaAppBindings.picker.searchPlaceholder"))
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
    }

    private func candidateRow(_ candidate: PersonaAppCandidate) -> some View {
        let exists = viewModel.hasPersonaAppRule(for: candidate)
        return Button {
            viewModel.personaAppBindingDraftIdentifier = candidate.preferredIdentifier
            viewModel.savePersonaAppBinding()
        } label: {
            HStack(spacing: 8) {
                PersonaAppIcon(identifier: candidate.preferredIdentifier, url: candidate.appURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.displayName).lineLimit(1)
                    Text(candidate.bundleIdentifier ?? candidate.preferredIdentifier)
                        .font(.subheadline).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if exists {
                    Text(L("personas.redesign.existingRule")).font(.subheadline)
                } else if candidate.isRunning {
                    Text(L("settings.personaAppBindings.picker.runningBadge")).font(.subheadline)
                        .foregroundStyle(StudioTheme.success)
                }
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(exists).opacity(exists ? 0.4 : 1)
    }
}
