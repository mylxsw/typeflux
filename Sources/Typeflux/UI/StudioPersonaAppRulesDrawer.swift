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
                Text(L("settings.personaAppBindings.title")).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TFColors.textPrimary)
                Spacer()
                TFButton(title: L("personas.redesign.close"), systemImage: "xmark", kind: .plain, iconOnly: true) {
                    viewModel.closePersonaAppRules()
                }
                .accessibilityIdentifier("personas.closeRules")
            }
            TFFormSection {
                TFFormRow(title: L("personas.redesign.enableRules"), icon: "app.badge.checkmark") {
                    TFSwitch(title: L("personas.redesign.enableRules"), isOn: Binding(
                        get: { viewModel.personaAppBindingsEnabled }, set: viewModel.setPersonaAppBindingsEnabled
                    ))
                    .accessibilityIdentifier("personas.rulesEnabled")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TFCard {
                        if viewModel.personaAppBindings.isEmpty {
                            TFCardNote(text: L("settings.personaAppBindings.empty"))
                        }
                        ForEach(viewModel.personaAppBindings) { binding in
                            rule(binding)
                            TFDivider.formWithIcon
                        }
                        TFActionRow(systemImage: "plus", title: L("settings.personaAppBindings.add")) {
                            viewModel.openPersonaAppRules(adding: true)
                        }
                    }
                    if viewModel.isAddingPersonaAppRule {
                        addFlow
                    }
                }
                .padding(1)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(TFColors.border).frame(width: TFMetrics.borderWidth) }
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
        let candidate = candidates.first {
            PersonaAppBinding.normalize($0.preferredIdentifier) == PersonaAppBinding.normalize(binding.appIdentifier)
        }
        return HStack(spacing: 12) {
            PersonaAppIcon(identifier: binding.appIdentifier, url: candidate?.appURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate?.displayName ?? binding.appIdentifier)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(TFColors.textPrimary).lineLimit(1)
                Text(binding.appIdentifier).font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(binding.isEnabled ? 1 : 0.5)
            .help(binding.appIdentifier)
            PersonaSelectionMenu(viewModel: viewModel, selection: binding.personaID) {
                viewModel.updatePersonaAppBindingPersona(id: binding.id, personaID: $0)
            }
            .frame(width: 170)
            .opacity(binding.isEnabled ? 1 : 0.5)
            TFSwitch(title: L("settings.personaAppBindings.binding.enable") + " " + binding.appIdentifier,
                     isOn: Binding(get: { binding.isEnabled },
                                   set: { viewModel.setPersonaAppBindingEnabled(id: binding.id, isEnabled: $0) }))
            TFButton(title: L("common.delete") + " " + binding.appIdentifier, systemImage: "trash", kind: .plain,
                     size: .small, iconOnly: true) {
                viewModel.removePersonaAppBinding(id: binding.id)
            }
        }
        .tfControlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(viewModel.personaAppBindingsEnabled ? 1 : 0.5)
    }

    private var addFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.personaAppBindings.addTitle")).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TFColors.textPrimary)
                Spacer()
                TFButton(title: L("common.cancel"), kind: .plain, size: .small) {
                    viewModel.isAddingPersonaAppRule = false
                }
            }
            PersonaSelectionMenu(viewModel: viewModel, selection: viewModel.personaAppBindingDraftPersonaID) {
                viewModel.personaAppBindingDraftPersonaID = $0
            }
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFSegmentedControl(options: PersonaAppPickerScope.allCases.map { TFOption($0, $0.title) },
                                   selection: $scope)
                TFSearchField(placeholder: L("settings.personaAppBindings.picker.searchPlaceholder"), text: $search,
                              placement: .container)
            }
            if loading {
                TFSpinner().frame(maxWidth: .infinity)
            } else if filteredCandidates.isEmpty {
                TFFootnote(text: L("settings.personaAppBindings.picker.empty"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredCandidates) { candidate in candidateRow(candidate) }
                    }
                }
                .frame(height: 180)
            }
            TFDivider(inset: 0)
            TFFootnote(text: L("personas.redesign.manualApp"))
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TextField(
                    L("settings.personaAppBindings.appIdentifierPlaceholder"),
                    text: $viewModel.personaAppBindingDraftIdentifier
                )
                .textFieldStyle(TFTextFieldStyle(monospaced: true))
                .onSubmit { viewModel.savePersonaAppBinding() }
                TFButton(title: L("settings.personaAppBindings.add"), kind: .primary) {
                    viewModel.savePersonaAppBinding()
                }
                .disabled(!viewModel.canSavePersonaAppBinding)
            }
            if viewModel.hasPersonaAppRule(viewModel.personaAppBindingDraftIdentifier) {
                TFFieldMessage(text: L("personas.redesign.existingRule"), tone: .hint)
            }
        }
        .padding(14)
        .tfCardSurface()
    }

    private func candidateRow(_ candidate: PersonaAppCandidate) -> some View {
        let exists = viewModel.hasPersonaAppRule(for: candidate)
        return Button {
            viewModel.personaAppBindingDraftIdentifier = candidate.preferredIdentifier
            viewModel.savePersonaAppBinding()
        } label: {
            HStack(spacing: 8) {
                PersonaAppIcon(identifier: candidate.preferredIdentifier, url: candidate.appURL, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName).font(.system(size: 13)).foregroundStyle(TFColors.textPrimary)
                        .lineLimit(1)
                    Text(candidate.bundleIdentifier ?? candidate.preferredIdentifier)
                        .font(.system(size: 11)).foregroundStyle(TFColors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if exists {
                    TFTag(text: L("personas.redesign.existingRule"))
                } else if candidate.isRunning {
                    TFStatusLabel(text: L("settings.personaAppBindings.picker.runningBadge"), level: .success)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(TFRowHoverStyle(selected: false))
        .disabled(exists).opacity(exists ? 0.4 : 1)
    }
}
