import AppKit
import Combine
import Foundation

enum OnboardingLLMProvider: Hashable, Identifiable, Sendable {
    case remote(LLMRemoteProvider)
    case ollama

    var id: String {
        switch self {
        case let .remote(provider):
            "remote_\(provider.rawValue)"
        case .ollama:
            "ollama"
        }
    }

    static var primaryOrder: [OnboardingLLMProvider] {
        [
            .remote(.freeModel),
            .remote(.openAI),
            .remote(.anthropic),
            .remote(.gemini),
            .remote(.deepSeek),
            .remote(.qwen),
            .remote(.openRouter),
            .ollama
        ]
    }

    static var moreProviders: [OnboardingLLMProvider] {
        LLMRemoteProvider.allCases.filter {
            $0 != .typefluxCloud && !primaryOrder.contains(.remote($0))
        }.map { .remote($0) }
    }

    var studioProviderID: StudioModelProviderID {
        switch self {
        case let .remote(provider):
            provider.studioProviderID
        case .ollama:
            .ollama
        }
    }
}

@MainActor
final class OnboardingLLMModel: ObservableObject {
    weak var session: OnboardingViewModel?

    enum ValidationStatus: Equatable {
        case idle
        case validating
        case valid
        case invalid(message: String)
    }

    enum TestStatus: Equatable {
        case idle
        case testing
        case success(preview: String, latencyMs: Int)
        case failure(message: String)
    }

    @Published private(set) var selectedProvider: OnboardingLLMProvider = .remote(.freeModel)
    @Published var apiKey = ""
    @Published var customBaseURL = ""
    @Published var availableModels: [String] = []
    @Published private(set) var selectedModel = ""
    @Published var isOllamaRunning = true
    @Published var validationStatus: ValidationStatus = .idle
    @Published var testStatus: TestStatus = .idle
    @Published var canContinue: Bool? = false
    @Published var isBusy = false
    @Published var primaryAction: (() -> Void)?

    var connectionProbe: (RegisteredProvider, SettingsStore.TextLLMConfiguration) async throws -> String = {
        try await OnboardingConnectionProbe.language(provider: $0, configuration: $1)
    }

    var validationDelay: TimeInterval = 0.6

    private var validationTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?
    private let catalog: any ProviderModelCatalog
    private var subscriptions = Set<AnyCancellable>()
    private var generation = UUID()
    private var isSyncing = false
    private var existingCustomProvider: RegisteredProvider?

    init(session: OnboardingViewModel, catalog: any ProviderModelCatalog = HTTPProviderModelCatalog()) {
        self.session = session
        self.catalog = catalog
        let store = session.settingsStore
        if let (provider, _) = session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference),
           !provider.isCloud,
           provider.remote != .freeModel || !FreeLLMModelRegistry.suggestedModelNames.isEmpty {
            selectedProvider = provider.isOllama ? .ollama : .remote(provider.remote ?? .custom)
        } else if store.llmProvider == .ollama {
            selectedProvider = .ollama
        } else if store.defaults.object(forKey: "llm.remote.provider") != nil,
                  store.llmRemoteProvider != .typefluxCloud {
            selectedProvider = .remote(store.llmRemoteProvider)
        }
        if selectedProvider == .remote(.freeModel), FreeLLMModelRegistry.suggestedModelNames.isEmpty {
            selectedProvider = .remote(.openAI)
        }
        $apiKey.dropFirst().sink { [weak self] _ in self?.scheduleValidation() }.store(in: &subscriptions)
        $customBaseURL.dropFirst().sink { [weak self] _ in self?.scheduleValidation() }.store(in: &subscriptions)
        session.$currentStep.dropFirst().sink { [weak self] step in
            if step != .llm, self?.validationTask != nil || self?.testTask != nil {
                self?.cancelPendingWork()
            }
        }.store(in: &subscriptions)
        syncFields(validate: false)
        if let (provider, model) = session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference),
           !provider.isCloud,
           provider.remote != .freeModel || !FreeLLMModelRegistry.suggestedModelNames.isEmpty {
            isSyncing = true
            let connection = session.modelLibrary.connection(provider, model: model)
            apiKey = connection.apiKey
            customBaseURL = connection.baseURL
            selectedModel = model.id
            if provider.remote == nil, !provider.isOllama {
                existingCustomProvider = provider
            }
            isSyncing = false
        }
    }

    deinit {
        validationTask?.cancel()
        testTask?.cancel()
    }

    var availablePrimaryProviders: [OnboardingLLMProvider] {
        OnboardingLLMProvider.primaryOrder.filter {
            $0 != .remote(.freeModel) || !FreeLLMModelRegistry.suggestedModelNames.isEmpty
        }
    }

    func selectProvider(_ provider: OnboardingLLMProvider) {
        guard provider != .remote(.freeModel) || !FreeLLMModelRegistry.suggestedModelNames.isEmpty,
              provider != selectedProvider else { return }
        cancelPendingWork()
        selectedProvider = provider
        syncFields()
    }
}

extension OnboardingLLMModel {
    func activate() {
        if selectedProvider == .remote(.freeModel) {
            commitCurrentSelection()
        } else if validationStatus == .valid {
            commitCurrentSelection()
        } else {
            scheduleValidation()
        }
    }

    private func syncFields(validate: Bool = true) {
        guard let store = session?.settingsStore else { return }
        isSyncing = true
        switch selectedProvider {
        case .remote(.freeModel):
            apiKey = ""
            customBaseURL = ""
            availableModels = FreeLLMModelRegistry.suggestedModelNames
            selectedModel = availableModels.contains(store.llmModel(for: .freeModel))
                ? store.llmModel(for: .freeModel) : availableModels.first ?? ""
        case .ollama:
            apiKey = ""
            customBaseURL = store.ollamaBaseURL
            selectedModel = store.ollamaModel
            availableModels = []
        case let .remote(remote):
            if remote == .custom, let existingCustomProvider {
                let config = session?.modelLibrary.connection(existingCustomProvider)
                apiKey = config?.apiKey ?? ""
                customBaseURL = config?.baseURL ?? ""
            } else {
                apiKey = store.llmAPIKey(for: remote)
                customBaseURL = store.llmBaseURL(for: remote)
            }
            selectedModel = store.llmModel(for: remote)
            availableModels = []
        }
        isSyncing = false
        if selectedProvider == .remote(.freeModel) {
            validationStatus = selectedModel.isEmpty ? .invalid(message: L("models.noModels")) : .valid
            canContinue = !selectedModel.isEmpty
            if validate {
                commitCurrentSelection()
            }
        } else if validate {
            scheduleValidation()
        }
    }

    func onKeyChange(_ newKey: String) {
        apiKey = newKey
    }

    private func scheduleValidation() {
        guard !isSyncing else { return }
        cancelPendingWork()
        guard selectedProvider != .remote(.freeModel) else { return }
        // Published values arrive before storage changes; yield before reading the signature.
        validationStatus = .validating
        isBusy = true
        let token = generation
        validationTask = Task { @MainActor [weak self] in
            do {
                let delay = self?.validationDelay ?? 0.6
                if delay > 0 {
                    try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled, let self, generation == token else { return }
                let (provider, config) = connectionConfiguration()
                let isOllama = selectedProvider == .ollama
                guard isOllama || (selectedProvider == .remote(.custom) && !config.baseURL.isEmpty) || !config.apiKey
                    .isEmpty
                else {
                    validationStatus = .idle
                    isBusy = false
                    return
                }
                let models = try await catalog.models(provider: provider, connection: config)
                guard !Task.isCancelled, generation == token else { return }
                applyCatalog(models)
            } catch {
                guard !Task.isCancelled, let self, generation == token else { return }
                isOllamaRunning = selectedProvider != .ollama
                validationStatus = .invalid(message: error.localizedDescription)
                canContinue = false
                isBusy = false
            }
        }
    }

    private func applyCatalog(_ models: [RegisteredModel]) {
        let ids = models.filter { $0.exclusionReason == nil }.map(\.id)
        // An empty Ollama catalog means no installed model; never invent installed models.
        isOllamaRunning = true
        guard !ids.isEmpty else {
            availableModels = []
            validationStatus = .invalid(message: L("models.noModels"))
            canContinue = false
            isBusy = false
            return
        }
        var unique = Array(Set(ids)).sorted()
        let recommended: String? = if case let .remote(remote) = selectedProvider {
            remote.suggestedModels.first(where: unique.contains)
        } else {
            nil
        }
        if let recommended {
            unique.removeAll { $0 == recommended }
            unique.insert(recommended, at: 0)
        }
        availableModels = unique
        if !unique.contains(selectedModel) {
            selectedModel = unique[0]
        }
        isOllamaRunning = true
        validationStatus = .valid
        isBusy = false
        commitCurrentSelection()
    }

    func checkOllama() {
        scheduleValidation()
    }

    func selectModel(_ model: String) {
        guard availableModels.contains(model) else { return }
        testTask?.cancel()
        generation = UUID()
        testStatus = .idle
        isBusy = false
        selectedModel = model
        commitCurrentSelection()
    }

    func cancelPendingWork() {
        generation = UUID()
        validationTask?.cancel()
        testTask?.cancel()
        validationTask = nil
        testTask = nil
        testStatus = .idle
        if validationStatus == .validating {
            validationStatus = .idle
        }
        canContinue = false
        isBusy = false
    }

    func testConnection() {
        guard validationStatus == .valid, !selectedModel.isEmpty, !isBusy else { return }
        testTask?.cancel()
        let token = generation
        let (provider, configuration) = connectionConfiguration()
        let probe = connectionProbe
        let signature = session?.languageConfigurationSignature
        testStatus = .testing
        isBusy = true
        testTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let start = Date()
            do {
                let reply = try await ConnectionTestSupport.runWithTimeout {
                    try await probe(provider, configuration)
                }
                guard !Task.isCancelled, let self, generation == token else { return }
                guard session?.languageConfigurationSignature == signature else {
                    cancelPendingWork()
                    return
                }
                guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AskStreamError.invalidResponse
                }
                testStatus = .success(preview: String(reply.prefix(120)),
                                      latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                isBusy = false
                commitCurrentSelection()
                session?.settingsStore.onboardingAIDeferred = false
            } catch {
                guard !Task.isCancelled, let self, generation == token else { return }
                guard session?.languageConfigurationSignature == signature else {
                    cancelPendingWork()
                    return
                }
                testStatus = .failure(message: error.localizedDescription)
                isBusy = false
            }
        }
    }

    func commitCurrentSelection() {
        guard validationStatus == .valid, !selectedModel.isEmpty,
              let session else { canContinue = false; return }
        let store = session.settingsStore
        let library = session.modelLibrary
        let providerID: String
        switch selectedProvider {
        case .ollama:
            providerID = "ollama"
            store.llmProvider = .ollama
            store.ollamaBaseURL = customBaseURL
            store.ollamaModel = selectedModel
        case let .remote(remote):
            providerID = remote == .custom ? existingCustomProvider?.id ?? remote.rawValue : remote.rawValue
            store.llmProvider = .openAICompatible
            store.llmRemoteProvider = remote
            store.setLLMAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: remote)
            if remote != .freeModel {
                store.setLLMBaseURL(customBaseURL, for: remote)
            }
            store.setLLMModel(selectedModel, for: remote)
        }
        do {
            if providerID == existingCustomProvider?.id, let existingCustomProvider {
                try library.updateConnection(existingCustomProvider, baseURL: customBaseURL,
                                             key: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try library.addModels([RegisteredModel(id: selectedModel, name: selectedModel)], providerID: providerID)
            guard let model = library.registry.providers.first(where: { $0.id == providerID })?.models
                .first(where: { $0.id == selectedModel }) else { canContinue = false; return }
            library.rewriteReference = model.reference
            library.defaultReference = model.reference
            syncMultimodalSpeech(providerID: providerID, model: model)
            canContinue = true
        } catch {
            validationStatus = .invalid(message: error.localizedDescription)
            canContinue = false
        }
    }

    private func syncMultimodalSpeech(providerID: String, model: RegisteredModel) {
        guard let session, session.settingsStore.sttProvider == .multimodalLLM,
              let provider = session.modelLibrary.registry.providers.first(where: { $0.id == providerID })
        else { return }
        let configuration = session.modelLibrary.connection(provider, model: model)
        var baseURL = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if provider.isOllama, !baseURL.hasSuffix("/v1") {
            baseURL += "/v1"
        }
        session.settingsStore.multimodalLLMBaseURL = baseURL
        session.settingsStore.multimodalLLMModel = configuration.model
        session.settingsStore.multimodalLLMAPIKey = configuration.apiKey
    }

    func connectionConfiguration() -> (RegisteredProvider, SettingsStore.TextLLMConfiguration) {
        let provider: RegisteredProvider = switch selectedProvider {
        case .ollama:
            RegisteredProvider(id: "ollama", name: "Ollama", baseURL: customBaseURL)
        case let .remote(remote):
            existingCustomProvider.flatMap { remote == .custom ? $0 : nil }
                ?? RegisteredProvider(id: remote.rawValue, name: remote.displayName,
                                      remote: remote, baseURL: customBaseURL)
        }
        return (provider, SettingsStore.TextLLMConfiguration(
            provider: provider.remote ?? .custom, baseURL: customBaseURL, model: selectedModel,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), apiStyle: provider.effectiveAPIStyle
        ))
    }

    var apiKeyHelpURL: URL? {
        guard case let .remote(remote) = selectedProvider else { return nil }
        switch remote {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .kimi: return URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .qwen: return URL(string: "https://dashscope.console.aliyun.com/apiKey")
        case .zhipu: return URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikey")
        case .minimax: return URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
        case .grok: return URL(string: "https://console.x.ai/")
        case .xiaomi: return URL(string: "https://ai.xiaomi.com/")
        default: return nil
        }
    }
}
