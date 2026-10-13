import SwiftUI

struct ModelSettingsPage<SpeechDetail: View>: View {
    @ObservedObject var viewModel: StudioViewModel
    @ObservedObject var library: AskModelLibrary
    @ObservedObject private var auth = AuthState.shared
    private var selectedProvider: String? {
        get { viewModel.selectedLanguageProviderID }
        nonmutating set { viewModel.selectedLanguageProviderID = newValue }
    }

    private var search: String {
        viewModel.modelSearchQuery
    }

    let speechDetail: () -> SpeechDetail

    var body: some View {
        VStack(spacing: 0) { content.id(viewModel.modelPageTab) }
            // Attached to a container that outlives tab switches, so changing tabs does not refetch the catalog.
            .task(id: auth.accessToken) {
                library.adoptLegacySelectionIfNeeded()
                if library.automaticallyLoadsCatalog {
                    await library.refresh(token: auth.accessToken)
                    await library.probeOllama()
                }
            }
            .sheet(isPresented: $viewModel.isAddingModelEndpoint) { AddModelEndpointView(library: library) }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.modelPageTab {
        case .scenes:
            TypefluxForm {
                Section {
                    TypefluxSettingsRow(L("ask.models.speech")) { speechSceneMenu }
                    TypefluxSettingsRow(L("ask.models.rewrite")) {
                        ModelScenePicker(library: library, reference: $library.rewriteReference,
                                         scenario: "rewrite", title: L("ask.models.rewrite"))
                    }
                    TypefluxSettingsRow(L("models.askDefault")) {
                        ModelScenePicker(library: library, reference: $library.defaultReference,
                                         scenario: "ask", title: L("models.askDefault"))
                    }
                }
                catalogError
            }
        case .providers, .local:
            if viewModel.isShowingSpeechProviderDetail {
                speechDetail()
            } else if let id = selectedProvider, library.providers.contains(where: { $0.id == id }) {
                ProviderModelsView(library: library, providerID: id, onBack: { selectedProvider = nil },
                                   backTitle: viewModel.modelPageTab.title).id(id)
            } else {
                TypefluxForm {
                    speechList
                    languageList
                    if !search.isEmpty, !hasMatchingProviders {
                        Text(String(format: L("models.searchEmpty"), search)).foregroundStyle(.secondary)
                    }
                    catalogError
                }
            }
        }
    }

    @ViewBuilder private var catalogError: some View {
        if let error = library.catalogError {
            Text(error).font(.subheadline).foregroundStyle(TypefluxColor.danger.color)
        }
    }

    private var speechSceneMenu: some View {
        TypefluxSearchablePopup(L("ask.models.speech"),
                                selectedTitle: speechModelName(viewModel.sttProvider)
                                    + (speechReason(viewModel.sttProvider).map { " — " + $0 } ?? ""),
                                searchPrompt: L("models.search"),
                                options: speechProviders.flatMap { provider -> [(
                                    label: String,
                                    value: SpeechModelSelection
                                )] in
                                    if provider == .localModel {
                                        return LocalSTTModel.displayOrder.filter { viewModel.isModelAvailable($0) }
                                            .map {
                                                (
                                                    label: $0.displayName,
                                                    value: SpeechModelSelection(provider: provider, localModel: $0)
                                                )
                                            }
                                    }
                                    let name = speechModelName(provider)
                                    return [(
                                        label: name == provider.displayName ? name : provider
                                            .displayName + " · " + name,
                                        value: SpeechModelSelection(provider: provider)
                                    )]
                                },
                                selection: Binding(
                                    get: { SpeechModelSelection(
                                        provider: viewModel.sttProvider,
                                        localModel: viewModel.sttProvider == .localModel ? viewModel.localSTTModel : nil
                                    ) },
                                    set: { selection in
                                        if let model = selection.localModel {
                                            viewModel.setLocalSTTModel(model)
                                        }
                                        viewModel.setSTTProvider(selection.provider)
                                    }
                                ))
                                .frame(width: 240)
                                .accessibilityIdentifier("models.scene.speech")
    }

    private var languageList: some View {
        let providers = library.configurationProviders.filter { ($0.isOllama) == (viewModel.modelPageTab == .local) }
        let groups = ModelSettingsPresentation.partition(
            providers,
            query: search,
            isAvailable: { library.unavailableReason($0, loggedIn: auth.isLoggedIn) == nil },
            searchTerms: { provider in [provider.name] + provider.configurationModels.flatMap { [$0.name, $0.id] } }
        )
        let rows: ([RegisteredProvider]) -> [ModelProviderRowData] = { items in
            items.map { provider in
                let reason = library.unavailableReason(provider, loggedIn: auth.isLoggedIn)
                return ModelProviderRowData(
                    id: provider.id,
                    name: provider.name,
                    detail: reason ?? ModelSettingsPresentation.languageProviderDetail(
                        modelCount: provider.configurationModels.count,
                        baseURL: endpoint(of: provider),
                        countFormat: L("models.count"),
                        managedLabel: provider.isCloud ? L("models.cloud.managedShort") : nil
                    ),
                    icon: provider.studioProviderID,
                    available: reason == nil
                )
            }
        }
        // The provider catalog is small. Fixed layout avoids lazy height corrections
        // while the wheel moves across configured/unconfigured groups.
        return providerGroups(
            title: L("models.tab.language"),
            connected: rows(groups.connected),
            unconfigured: rows(groups.unconfigured)
        ) { selectedProvider = $0 }
    }

    private var speechProviders: [STTProvider] {
        ModelAvailability.configurationSpeechProviders.filter {
            if $0 == .localModel {
                return LocalSTTModel.displayOrder.contains { viewModel.isModelAvailable($0) }
            }
            return speechReason($0) == nil
        }
    }

    private var speechProviderOrder: [STTProvider] {
        var values = ModelAvailability.configurationSpeechProviders
        if viewModel.sttProvider == .appleSpeech {
            values.append(.appleSpeech)
        }
        return values.filter { ($0 == .localModel) == (viewModel.modelPageTab == .local) }
    }

    private var speechList: some View {
        let reasons = Dictionary(
            speechProviderOrder.map { ($0, speechReason($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let groups = ModelSettingsPresentation.partition(
            speechProviderOrder,
            query: search,
            isAvailable: { (reasons[$0] ?? nil) == nil },
            searchTerms: { [$0.displayName, speechModelName($0)] }
        )
        let rows: ([STTProvider]) -> [ModelProviderRowData] = { items in
            items.map { provider in
                let reason = reasons[provider] ?? nil
                return ModelProviderRowData(
                    id: provider.rawValue,
                    name: provider.displayName,
                    detail: reason ?? "",
                    icon: provider.studioProviderID,
                    available: reason == nil
                )
            }
        }
        return providerGroups(
            title: L("ask.models.speech"),
            connected: rows(groups.connected),
            unconfigured: rows(groups.unconfigured)
        ) { id in
            guard let provider = STTProvider(rawValue: id) else { return }
            viewModel.setModelDomain(.stt)
            viewModel.focusModelProvider(provider.studioProviderID)
            viewModel.isShowingSpeechProviderDetail = true
        }
    }
}

extension ModelSettingsPage {
    private func endpoint(of provider: RegisteredProvider) -> String {
        if provider.isCloud || provider.remote == .freeModel {
            return ""
        }
        if let remote = provider.remote {
            return library.settings.llmBaseURL(for: remote)
        }
        return provider.isOllama ? library.settings.ollamaBaseURL : provider.baseURL
    }

    private func providerGroups(
        title: String,
        connected: [ModelProviderRowData],
        unconfigured: [ModelProviderRowData],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Group {
            if !connected.isEmpty {
                TypefluxFormSection(title + " · " + L("models.configured")) {
                    ForEach(connected) { row in ModelProviderRow(row: row) { onSelect(row.id) } }
                }
            }
            if !unconfigured.isEmpty {
                TypefluxFormSection(title + " · " + L("models.notConfigured")) {
                    ForEach(unconfigured) { row in ModelProviderRow(row: row) { onSelect(row.id) } }
                }
            }
        }
    }

    private var hasMatchingProviders: Bool {
        speechProviderOrder.contains {
            ModelSettingsPresentation.matches(search, terms: [$0.displayName, speechModelName($0)])
        } || library.configurationProviders.contains { provider in
            provider.isOllama == (viewModel.modelPageTab == .local)
                && ModelSettingsPresentation.matches(search, terms: [provider.name]
                    + provider.configurationModels.flatMap { [$0.name, $0.id] })
        }
    }

    private func speechReason(_ provider: STTProvider) -> String? {
        // Only local/Cloud availability needs to inspect local model files.
        let needsLocal = provider == .localModel || (provider == .typefluxOfficial && !auth.isLoggedIn)
        return ModelAvailability.speechReason(provider, settings: library.settings, loggedIn: auth.isLoggedIn,
                                              localModelAvailable: needsLocal && viewModel.isModelAvailable(
                                                  provider == .typefluxOfficial ? .senseVoiceSmall : viewModel
                                                      .localSTTModel
                                              ),
                                              googleAuthorized: viewModel.googleCloudOAuthAuthorized)
    }

    private func speechModelName(_ provider: STTProvider) -> String {
        switch provider {
        case .localModel: viewModel.localSTTModel.displayName
        case .whisperAPI: viewModel.whisperModel
        case .multimodalLLM: viewModel.multimodalLLMModel
        case .aliCloud: viewModel.aliCloudModel
        case .googleCloud: viewModel.googleCloudModel
        case .groq: viewModel.groqSTTModel
        case .soniox: viewModel.sonioxModel
        case .freeModel: viewModel.freeSTTModel
        case .doubaoRealtime: viewModel.doubaoResourceID
        case .typefluxOfficial, .appleSpeech: provider.displayName
        }
    }
}

extension STTProvider {
    var studioProviderID: StudioModelProviderID {
        switch self {
        case .typefluxOfficial: .typefluxOfficial
        case .freeModel: .freeSTT
        case .localModel: .localSTT
        case .whisperAPI: .whisperAPI
        case .multimodalLLM: .multimodalLLM
        case .aliCloud: .aliCloud
        case .doubaoRealtime: .doubaoRealtime
        case .googleCloud: .googleCloud
        case .groq: .groqSTT
        case .soniox: .soniox
        case .appleSpeech: .appleSpeech
        }
    }
}

/// Keeps local model identity alongside its provider when selecting a speech scene.
private struct SpeechModelSelection: Hashable {
    let provider: STTProvider
    var localModel: LocalSTTModel?
}
