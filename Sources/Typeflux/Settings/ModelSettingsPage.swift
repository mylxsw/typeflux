import SwiftUI

struct ModelSettingsPage<SpeechDetail: View>: View {
    @ObservedObject var viewModel: StudioViewModel
    @ObservedObject var library: AskModelLibrary
    @ObservedObject private var auth = AuthState.shared
    @State private var selectedProvider: String?
    @State private var speechDetailVisible = false
    @State private var search = ""
    @State private var addingEndpoint = false
    let speechDetail: () -> SpeechDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if speechDetailVisible {
                    backButton { speechDetailVisible = false }
                    speechDetail()
                } else if let id = selectedProvider, let provider = library.providers.first(where: { $0.id == id }) {
                    backButton { selectedProvider = nil }
                    ProviderModelsView(library: library, providerID: provider.id)
                } else {
                    scenes
                    HStack {
                        StudioSegmentedPicker(options: StudioModelDomain.allCases.map {
                            (
                                label: L($0 == .stt ? "settings.models.domain.stt" : "settings.models.domain.llm"),
                                value: $0
                            )
                        }, selection: Binding(get: { viewModel.modelDomain }, set: viewModel.setModelDomain))
                        Spacer()
                        TextField(L("models.search"), text: $search).textFieldStyle(.roundedBorder).frame(width: 210)
                    }
                    if viewModel.modelDomain == .stt {
                        speechList
                    } else {
                        languageList
                    }
                    if let error = library.catalogError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }.padding(2)
        }
        .task {
            library.adoptLegacySelectionIfNeeded()
            if library.automaticallyLoadsCatalog {
                await library.refresh(token: auth.accessToken)
                await library.probeOllama()
            }
        }
        .sheet(isPresented: $addingEndpoint) { AddModelEndpointView(library: library) }
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(L("models.back"), systemImage: "chevron.left") }.buttonStyle(.plain)
    }

    private var scenes: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 15) {
                Text(L("ask.models.byPurpose")).font(.headline)
                Text(L("models.sceneHint")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                Divider()
                sceneRow("ask.models.speech", subtitle: "models.fixedSpeech", icon: "mic") {
                    Menu {
                        ForEach(speechProviders, id: \.rawValue) { provider in
                            Section(provider.displayName) {
                                if provider == .localModel {
                                    ForEach(LocalSTTModel.displayOrder, id: \.rawValue) { model in
                                        Button(model.displayName) {
                                            viewModel.setLocalSTTModel(model); viewModel.setSTTProvider(provider)
                                        }
                                        .disabled(!viewModel.isModelAvailable(model))
                                    }
                                } else {
                                    Button(speechModelName(provider)) { viewModel.setSTTProvider(provider) }
                                        .disabled(speechReason(provider) != nil)
                                }
                                if let reason = speechReason(provider) {
                                    Text(reason)
                                }
                            }
                        }
                    } label: { Text(viewModel.sttProvider.displayName + " · " + speechModelName(viewModel.sttProvider)
                            + (speechReason(viewModel.sttProvider).map { " — " + $0 } ?? ""))
                    }
                    .menuStyle(.borderlessButton).frame(width: 280)
                }
                Divider()
                sceneRow("ask.models.rewrite", subtitle: "models.fixedRewrite", icon: "pencil") {
                    AskModelMenu(library: library, reference: $library.rewriteReference, showsDefaultAction: false)
                }
                Divider()
                sceneRow("models.askDefault", subtitle: "models.defaultHint", icon: "sparkles") {
                    AskModelMenu(library: library, reference: $library.defaultReference, showsDefaultAction: false)
                }
            }
        }
    }

    private func sceneRow(_ title: String, subtitle: String, icon: String,
                          @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 30).foregroundStyle(StudioTheme.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).font(.system(size: 13, weight: .semibold))
                Text(L(subtitle)).font(.caption).foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            content()
        }
    }

    private var languageList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([true, false], id: \.self) { configured in
                Text(L(configured ? "models.configured" : "models.unconfigured"))
                    .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.textSecondary).padding(.top, 6)
                ForEach(library.sortedProviders(loggedIn: auth.isLoggedIn).filter {
                    (library.unavailableReason($0, loggedIn: auth.isLoggedIn) == nil) == configured &&
                        (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                }) { provider in
                    providerRow(name: provider.name,
                                detail: library.unavailableReason(provider, loggedIn: auth.isLoggedIn) ?? provider
                                    .models.map(\.id).joined(separator: " · "),
                                available: configured, icon: provider.isCloud ? "cloud" : "server.rack") {
                        selectedProvider = provider.id
                    }
                }
            }
            Button { addingEndpoint = true } label: { Label(L("models.addEndpoint"), systemImage: "plus") }.padding(
                .top,
                8
            )
        }
    }

    private var speechProviders: [STTProvider] {
        var values = STTProvider.settingsDisplayOrder
        if viewModel.sttProvider == .appleSpeech {
            values.append(.appleSpeech)
        }
        return ModelAvailability.sorted(values) { speechReason($0) == nil }
    }

    private var speechList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([true, false], id: \.self) { configured in
                Text(L(configured ? "models.configured" : "models.unconfigured"))
                    .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.textSecondary).padding(.top, 6)
                ForEach(speechProviders.filter {
                    (speechReason($0) == nil) == configured &&
                        (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search))
                }, id: \.rawValue) { provider in
                    providerRow(
                        name: provider.displayName,
                        detail: speechReason(provider) ?? speechModelName(provider),
                        available: configured,
                        icon: "waveform"
                    ) {
                        viewModel.focusModelProvider(provider.studioProviderID)
                        speechDetailVisible = true
                    }
                }
            }
        }
    }

    private func providerRow(name: String, detail: String, available: Bool, icon: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 36, height: 36)
                    .background(StudioTheme.textSecondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
                }
                Spacer()
                if available {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Text(L(available ? "models.connected" : "models.notConfigured")).font(.caption)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(StudioTheme.textSecondary.opacity(0.08), in: Capsule())
                Image(systemName: "chevron.right").font(.caption)
            }.padding(14)
                .foregroundStyle(available ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .background(
                    StudioTheme.textSecondary.opacity(available ? 0.08 : 0.025),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                    StudioTheme.border,
                    style: StrokeStyle(lineWidth: 1, dash: available ? [] : [4, 3])
                ))
        }.buttonStyle(.plain)
    }

    private func speechReason(_ provider: STTProvider) -> String? {
        if provider != .localModel, auth.isLoggedIn && !auth.canUseCloudASR { return L("models.subscription") }
        return ModelAvailability.speechReason(provider, settings: library.settings, loggedIn: auth.isLoggedIn,
                                       localModelAvailable: viewModel.isModelAvailable(viewModel.localSTTModel),
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
