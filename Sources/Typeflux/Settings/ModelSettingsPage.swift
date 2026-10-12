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
        VStack(spacing: 0) { content }
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch viewModel.modelPageTab {
                case .scenes:
                    scenes
                    catalogError
                case .speech:
                    if viewModel.isShowingSpeechProviderDetail {
                        backButton { viewModel.isShowingSpeechProviderDetail = false }.padding(.bottom, 16)
                        speechDetail()
                    } else {
                        speechList
                    }
                case .language:
                    if let id = selectedProvider, library.providers.contains(where: { $0.id == id }) {
                        ProviderModelsView(library: library, providerID: id) { selectedProvider = nil }
                    } else {
                        languageList
                        catalogError
                    }
                }
            }.padding(2).padding(.bottom, StudioTheme.Layout.shellContentBottomInset)
        }
        // Each tab opens at its top rather than at the previous tab's scroll position.
        .id(viewModel.modelPageTab)
    }

    @ViewBuilder private var catalogError: some View {
        if let error = library.catalogError {
            Text(error).font(.caption).foregroundStyle(StudioTheme.danger).padding(.top, 10)
        }
    }

    /// Returns from a speech provider's settings to the speech provider list.
    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(ModelPageTab.speech.title, systemImage: "chevron.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var scenes: some View {
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                sceneRow("ask.models.speech", icon: "mic") {
                    speechSceneMenu
                }
                ModelRowDivider(leading: 66)
                sceneRow("ask.models.rewrite", icon: "pencil") {
                    AskModelMenu(
                        library: library,
                        reference: $library.rewriteReference,
                        scenario: "rewrite",
                        showsDefaultAction: false,
                        fieldStyle: true
                    )
                }
                ModelRowDivider(leading: 66)
                sceneRow("models.askDefault", icon: "sparkles") {
                    AskModelMenu(
                        library: library,
                        reference: $library.defaultReference,
                        showsDefaultAction: false,
                        fieldStyle: true
                    )
                }
            }
        }
    }

    private var speechSceneMenu: some View {
        HStack(spacing: 8) {
            ModelProviderIcon(provider: viewModel.sttProvider.studioProviderID, size: 16)
            Menu {
                ForEach(speechProviders, id: \.rawValue) { provider in
                    Section(provider.displayName) {
                        if provider == .localModel {
                            ForEach(
                                LocalSTTModel.displayOrder.filter { viewModel.isModelAvailable($0) },
                                id: \.rawValue
                            ) { model in
                                Button(model.displayName) {
                                    viewModel.setLocalSTTModel(model); viewModel.setSTTProvider(provider)
                                }
                            }
                        } else {
                            Button(speechModelName(provider)) { viewModel.setSTTProvider(provider) }
                        }
                    }
                }
            } label: {
                Text(speechModelName(viewModel.sttProvider)
                    + (speechReason(viewModel.sttProvider).map { " — " + $0 } ?? ""))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same up/down indicator as the other scene selectors; clicks fall through to the menu.
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .allowsHitTesting(false)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(width: 240, height: 30, alignment: .leading)
        .background(
            ModelVisualStyle.control,
            in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                .strokeBorder(ModelVisualStyle.border)
        )
    }

    private func sceneRow(_ title: String, icon: String,
                          @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 14) {
            ModelIconTile {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(StudioTheme.textSecondary)
            }
            Text(L(title)).font(.system(size: StudioTheme.Typography.settingTitle, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer(minLength: 16)
            content()
        }.padding(.horizontal, 18).padding(.vertical, 14).frame(minHeight: 68)
    }

    private var languageList: some View {
        let providers = library.configurationProviders
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
            connected: rows(groups.connected),
            unconfigured: rows(groups.unconfigured)
        ) { selectedProvider = $0 }
    }

    private var speechProviders: [STTProvider] {
        speechProviderOrder.filter {
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
        return values
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
            connected: rows(groups.connected),
            unconfigured: rows(groups.unconfigured)
        ) { id in
            guard let provider = STTProvider(rawValue: id) else { return }
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
        connected: [ModelProviderRowData],
        unconfigured: [ModelProviderRowData],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !connected.isEmpty {
                ModelSectionLabel(title: L("models.configured"), detail: "\(connected.count)")
                    .padding(.bottom, 8)
                providerSurface(connected, onSelect: onSelect)
            }
            if !unconfigured.isEmpty {
                ModelSectionLabel(title: L("models.notConfigured"), detail: "\(unconfigured.count)")
                    .padding(.top, connected.isEmpty ? 0 : 22).padding(.bottom, 8)
                providerSurface(unconfigured, onSelect: onSelect)
            }
            if connected.isEmpty && unconfigured.isEmpty && !search.trimmingCharacters(in: .whitespaces).isEmpty {
                ModelSurface {
                    Text(String(format: L("models.searchEmpty"), search))
                        .font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 26)
                }
            }
        }
    }

    private func providerSurface(
        _ rows: [ModelProviderRowData],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        ModelSurface {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        ModelRowDivider(leading: 66)
                    }
                    ModelProviderRow(row: row) { onSelect(row.id) }
                }
            }
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
