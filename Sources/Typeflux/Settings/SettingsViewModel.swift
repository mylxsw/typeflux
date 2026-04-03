import AppKit
import Foundation
import SwiftUI

enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(firstTokenMs: Int, totalMs: Int, preview: String)
    case failure(message: String)
}

enum MCPTransportType: String, CaseIterable {
    case stdio
    case http
}

enum MCPConnectionTestState: Equatable {
    case idle
    case testing
    case success(tools: [MCPDiscoveredTool])
    case failure(message: String)

    struct MCPDiscoveredTool: Equatable, Identifiable {
        let id: String
        let name: String
        let description: String
    }
}

@MainActor
final class StudioViewModel: ObservableObject {
    private static let historyPageSize = 100

    @Published var currentSection: StudioSection
    @Published var searchQuery = "" {
        didSet {
            if currentSection == .home || currentSection == .history {
                refreshHistory(reset: true)
            }
        }
    }
    @Published var modelDomain: StudioModelDomain = .stt
    @Published var focusedModelProvider: StudioModelProviderID

    @Published var sttProvider: STTProvider
    @Published var llmProvider: LLMProvider
    @Published var llmRemoteProvider: LLMRemoteProvider
    @Published var appearanceMode: AppearanceMode
    @Published var appLanguage: AppLanguage
    @Published var availableMicrophones: [AudioInputDevice] = []
    @Published var preferredMicrophoneID: String
    @Published var muteSystemOutputDuringRecording: Bool
    @Published var soundEffectsEnabled: Bool

    @Published var llmBaseURL: String
    @Published var llmModel: String
    @Published var llmAPIKey: String

    @Published var ollamaBaseURL: String
    @Published var ollamaModel: String
    @Published var ollamaAutoSetup: Bool
    @Published var ollamaStatus = L("settings.models.ollama.notPrepared")
    @Published var isPreparingOllama = false

    @Published var whisperBaseURL: String
    @Published var whisperModel: String
    @Published var whisperAPIKey: String
    @Published var freeSTTModel: String

    @Published var multimodalLLMBaseURL: String
    @Published var multimodalLLMModel: String
    @Published var multimodalLLMAPIKey: String

    @Published var aliCloudAPIKey: String
    @Published var doubaoAppID: String
    @Published var doubaoAccessToken: String
    @Published var doubaoResourceID: String

    @Published var localSTTModel: LocalSTTModel
    @Published var localSTTModelIdentifier: String
    @Published var localSTTDownloadSource: ModelDownloadSource
    @Published var localSTTAutoSetup: Bool
    @Published var localSTTStatus = L("settings.models.localSTT.notPrepared")
    @Published var localSTTPreparationProgress: Double = 0
    @Published var localSTTPreparationDetail = L("settings.models.localSTT.autoPrepareHint")
    @Published var localSTTStoragePath: String
    @Published var localSTTPreparedSource = L("common.automatic")
    @Published var isLocalSTTPrepared = false
    @Published var isPreparingLocalSTT = false
    @Published var localSTTPendingDelete: LocalSTTModel? = nil
    @Published var localSTTPendingRedownload: LocalSTTModel? = nil

    @Published var appleSpeechFallback: Bool
    @Published var automaticVocabularyCollectionEnabled: Bool

    @Published var agentFrameworkEnabled: Bool
    @Published var agentStepLoggingEnabled: Bool
    @Published var mcpServers: [MCPServerConfig]
    @Published var mcpDraftName: String = ""
    @Published var mcpDraftTransportType: MCPTransportType = .stdio
    @Published var mcpDraftStdioCommand: String = ""
    @Published var mcpDraftStdioArgs: String = ""
    @Published var mcpDraftStdioEnv: String = ""
    @Published var mcpDraftHTTPURL: String = ""
    @Published var mcpDraftHTTPHeaders: String = ""
    @Published var mcpDraftEnabled: Bool = true
    @Published var mcpDraftAutoConnect: Bool = false
    @Published var mcpDraftEditingServerID: UUID? = nil
    @Published var mcpConnectionTestTargetServerID: UUID? = nil
    @Published var mcpConnectionTestState: MCPConnectionTestState = .idle

    @Published var personaRewriteEnabled: Bool
    @Published var personaHotkeyAppliesToSelection: Bool
    @Published var personas: [PersonaProfile]
    @Published var selectedPersonaID: UUID?
    @Published private(set) var activePersonaID: String
    @Published var personaDraftName: String
    @Published var personaDraftPrompt: String
    @Published private(set) var isCreatingPersonaDraft: Bool
    @Published var vocabularyEntries: [VocabularyEntry]

    @Published var launchAtLogin: Bool
    @Published var activationHotkey: HotkeyBinding
    @Published var askHotkey: HotkeyBinding
    @Published var personaHotkey: HotkeyBinding
    @Published var historyRetentionPolicy: HistoryRetentionPolicy
    @Published private(set) var historyRecords: [HistoryRecord]
    @Published var toastMessage: String?
    @Published var llmConnectionTestState: ConnectionTestState = .idle
    @Published var sttConnectionTestState: ConnectionTestState = .idle
    @Published private(set) var permissionRows: [StudioPermissionRowModel] = []
    @Published private(set) var isRefreshingPermissions = false
    @Published private(set) var isRefreshingHistory = false
    @Published private(set) var isLoadingMoreHistory = false
    @Published private(set) var canLoadMoreHistory = false

    let errorLogStore = ErrorLogStore.shared

    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let modelManager: OllamaLocalModelManager
    private let localSTTServiceManager: LocalSTTServiceManager
    private let audioDeviceManager: AudioDeviceManager
    private let onRetryHistory: (HistoryRecord) -> Void
    private var historyObserver: NSObjectProtocol?
    private var personaSelectionObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var vocabularyObserver: NSObjectProtocol?
    private var llmTestTask: Task<Void, Never>?
    private var sttTestTask: Task<Void, Never>?
    private var mcpTestTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        initialSection: StudioSection,
        onRetryHistory: @escaping (HistoryRecord) -> Void = { _ in },
        modelManager: OllamaLocalModelManager = OllamaLocalModelManager(),
        localSTTServiceManager: LocalSTTServiceManager = LocalSTTServiceManager(),
        audioDeviceManager: AudioDeviceManager = AudioDeviceManager()
    ) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.modelManager = modelManager
        self.localSTTServiceManager = localSTTServiceManager
        self.audioDeviceManager = audioDeviceManager
        self.onRetryHistory = onRetryHistory

        let currentPersonas = settingsStore.personas

        currentSection = initialSection
        let initialSTTProvider = Self.visibleSTTProvider(from: settingsStore.sttProvider)
        let initialLLMRemoteProvider = settingsStore.llmRemoteProvider
        if initialSTTProvider != settingsStore.sttProvider {
            settingsStore.sttProvider = initialSTTProvider
        }
        sttProvider = initialSTTProvider
        llmProvider = settingsStore.llmProvider
        llmRemoteProvider = initialLLMRemoteProvider
        switch initialSTTProvider {
        case .freeModel:
            focusedModelProvider = .freeSTT
        case .appleSpeech:
            focusedModelProvider = .appleSpeech
        case .localModel:
            focusedModelProvider = .localSTT
        case .whisperAPI:
            focusedModelProvider = .whisperAPI
        case .multimodalLLM:
            focusedModelProvider = .multimodalLLM
        case .aliCloud:
            focusedModelProvider = .aliCloud
        case .doubaoRealtime:
            focusedModelProvider = .doubaoRealtime
        }
        appearanceMode = settingsStore.appearanceMode
        appLanguage = settingsStore.appLanguage
        preferredMicrophoneID = settingsStore.preferredMicrophoneID
        muteSystemOutputDuringRecording = settingsStore.muteSystemOutputDuringRecording
        soundEffectsEnabled = settingsStore.soundEffectsEnabled
        llmBaseURL = settingsStore.llmBaseURL(for: initialLLMRemoteProvider)
        llmModel = settingsStore.llmModel(for: initialLLMRemoteProvider)
        llmAPIKey = settingsStore.llmAPIKey(for: initialLLMRemoteProvider)
        ollamaBaseURL = settingsStore.ollamaBaseURL
        ollamaModel = settingsStore.ollamaModel
        ollamaAutoSetup = settingsStore.ollamaAutoSetup
        whisperBaseURL = settingsStore.whisperBaseURL
        whisperModel = settingsStore.whisperModel
        whisperAPIKey = settingsStore.whisperAPIKey
        freeSTTModel = settingsStore.freeSTTModel
        multimodalLLMBaseURL = settingsStore.multimodalLLMBaseURL
        multimodalLLMModel = settingsStore.multimodalLLMModel
        multimodalLLMAPIKey = settingsStore.multimodalLLMAPIKey
        aliCloudAPIKey = settingsStore.aliCloudAPIKey
        doubaoAppID = settingsStore.doubaoAppID
        doubaoAccessToken = settingsStore.doubaoAccessToken
        doubaoResourceID = settingsStore.doubaoResourceID
        localSTTModel = settingsStore.localSTTModel
        localSTTModelIdentifier = settingsStore.localSTTModel.defaultModelIdentifier
        localSTTDownloadSource = settingsStore.localSTTDownloadSource
        localSTTAutoSetup = true
        localSTTStoragePath = ""
        appleSpeechFallback = settingsStore.useAppleSpeechFallback
        automaticVocabularyCollectionEnabled = settingsStore.automaticVocabularyCollectionEnabled
        agentFrameworkEnabled = settingsStore.agentFrameworkEnabled
        agentStepLoggingEnabled = settingsStore.agentStepLoggingEnabled
        mcpServers = settingsStore.mcpServers
        personaRewriteEnabled = settingsStore.personaRewriteEnabled
        personaHotkeyAppliesToSelection = settingsStore.personaHotkeyAppliesToSelection
        personas = currentPersonas
        let initialSelectedPersonaID = settingsStore.activePersona.map(\.id) ?? currentPersonas.first?.id
        selectedPersonaID = initialSelectedPersonaID
        activePersonaID = settingsStore.activePersonaID
        let initialPersona = currentPersonas.first(where: { $0.id == initialSelectedPersonaID }) ?? currentPersonas.first
        personaDraftName = initialPersona?.name ?? ""
        personaDraftPrompt = initialPersona?.prompt ?? ""
        isCreatingPersonaDraft = false
        vocabularyEntries = VocabularyStore.load()
        launchAtLogin = LaunchAtLoginManager.isEnabled
        activationHotkey = settingsStore.activationHotkey
        askHotkey = settingsStore.askHotkey
        personaHotkey = settingsStore.personaHotkey
        historyRetentionPolicy = settingsStore.historyRetentionPolicy
        historyRecords = []
        displayedHistory = []
        settingsStore.localSTTModelIdentifier = localSTTModelIdentifier
        settingsStore.localSTTDownloadSource = localSTTModel.recommendedDownloadSource
        settingsStore.localSTTAutoSetup = true
        applyHistoryRetentionPolicy()
        refreshHistory(reset: true)
        refreshAvailableMicrophones()
        refreshLocalSTTStoragePath()
        refreshLocalSTTPreparedState()
        historyObserver = NotificationCenter.default.addObserver(
            forName: .historyStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshHistory()
            }
        }
        personaSelectionObserver = NotificationCenter.default.addObserver(
            forName: .personaSelectionDidChange,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncPersonaSelectionFromStore()
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appearanceMode = self.settingsStore.appearanceMode
            }
        }
        vocabularyObserver = NotificationCenter.default.addObserver(
            forName: .vocabularyStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let entries = notification.userInfo?["entries"] as? [VocabularyEntry] {
                    self.vocabularyEntries = entries
                } else {
                    self.vocabularyEntries = VocabularyStore.load()
                }
            }
        }
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
        if let personaSelectionObserver {
            NotificationCenter.default.removeObserver(personaSelectionObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let vocabularyObserver {
            NotificationCenter.default.removeObserver(vocabularyObserver)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var locale: Locale {
        Locale(identifier: appLanguage.localeIdentifier)
    }

    var localSTTPreparationPercentText: String {
        "\(Int((localSTTPreparationProgress * 100).rounded()))%"
    }

    var localSTTPreparationTint: Color {
        if isLocalSTTPrepared {
            return StudioTheme.success
        }

        if localSTTStatus.hasPrefix(L("common.failedPrefix")) {
            return StudioTheme.danger
        }

        return StudioTheme.accent
    }

    var isOllamaFailed: Bool {
        !isPreparingOllama && ollamaStatus.hasPrefix(L("common.failedPrefix"))
    }

    var localSTTNeedsRetry: Bool {
        !isPreparingLocalSTT && !isLocalSTTPrepared
    }

    @Published private(set) var displayedHistory: [HistoryPresentationRecord] = []

    var groupedHistory: [HistorySection] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: displayedHistory) { record in
            calendar.startOfDay(for: record.date)
        }

        return groups.keys.sorted(by: >).map { date in
            let title: String
            if calendar.isDateInToday(date) {
                title = L("history.section.today")
            } else if calendar.isDateInYesterday(date) {
                title = L("history.section.yesterday")
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                title = formatter.string(from: date)
            }

            let recordsForDate = groups[date]!.sorted { $0.date > $1.date }
            return HistorySection(id: title, records: recordsForDate)
        }
    }

    var selectedPersona: PersonaProfile? {
        guard let selectedPersonaID else { return nil }
        return personas.first { $0.id == selectedPersonaID }
    }

    var selectedPersonaIsSystem: Bool {
        selectedPersona?.isSystem ?? false
    }

    var hasPersonaDraftChanges: Bool {
        if isCreatingPersonaDraft {
            return !personaDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !personaDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard let selectedPersona else { return false }
        guard !selectedPersona.isSystem else { return false }
        return personaDraftName != selectedPersona.name || personaDraftPrompt != selectedPersona.prompt
    }

    var canSavePersonaDraft: Bool {
        !selectedPersonaIsSystem && !personaDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredPersonas: [PersonaProfile] {
        guard !searchQuery.isEmpty else { return personas }
        return personas.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.prompt.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var filteredVocabularyEntries: [VocabularyEntry] {
        guard !searchQuery.isEmpty else { return vocabularyEntries }
        return vocabularyEntries.filter { $0.term.localizedCaseInsensitiveContains(searchQuery) }
    }

    private let statsStore = UsageStatsStore.shared

    var transcriptionMinutesText: String {
        statsStore.totalDictationMinutesText
    }

    var completedTranscriptionsText: String {
        NumberFormatter.localizedString(from: NSNumber(value: statsStore.totalSessions), number: .decimal)
    }

    var statsCompletionRate: Int {
        statsStore.completionRate
    }

    var statsTotalCharacters: Int {
        statsStore.totalCharacterCount
    }

    var statsSavedMinutes: Int {
        statsStore.savedMinutes
    }

    var statsAveragePaceWPM: Int {
        statsStore.averagePaceWPM
    }

    var architectureCards: [StudioModelCard] {
        switch modelDomain {
        case .stt:
            return [
                StudioModelCard(
                    id: "apple-speech",
                    name: "Apple Speech",
                    summary: "On-device system recognizer for low-friction local transcription.",
                    badge: "Local",
                    metadata: "Built-in • Offline friendly",
                    isSelected: sttProvider == .appleSpeech,
                    isMuted: false,
                    actionTitle: sttProvider == .appleSpeech ? "Selected" : "Use Local"
                ),
                StudioModelCard(
                    id: "local-stt",
                    name: "Local Models",
                    summary: "Run curated local speech models such as Whisper, SenseVoice, or Qwen3-ASR through an embedded service.",
                    badge: "Local",
                    metadata: localSTTModel.displayName,
                    isSelected: sttProvider == .localModel,
                    isMuted: false,
                    actionTitle: sttProvider == .localModel ? "Selected" : "Use Local"
                ),
                StudioModelCard(
                    id: "whisper-api",
                    name: "Whisper API",
                    summary: "Cloud or gateway-backed transcription using OpenAI-compatible APIs.",
                    badge: "Remote",
                    metadata: whisperModel.isEmpty ? "Model not set" : whisperModel,
                    isSelected: sttProvider == .whisperAPI,
                    isMuted: false,
                    actionTitle: sttProvider == .whisperAPI ? "Selected" : "Use Remote"
                ),
                StudioModelCard(
                    id: "multimodal-llm",
                    name: "Multimodal LLM",
                    summary: "Send audio directly to a multimodal LLM. Transcription and persona rewriting happen in a single API call.",
                    badge: "Remote",
                    metadata: multimodalLLMModel.isEmpty ? "Model not configured" : multimodalLLMModel,
                    isSelected: sttProvider == .multimodalLLM,
                    isMuted: false,
                    actionTitle: sttProvider == .multimodalLLM ? "Selected" : "Use Multimodal"
                )
            ]

        case .llm:
            return [
                StudioModelCard(
                    id: "ollama-local",
                    name: "Local Ollama",
                    summary: "Runs rewritten output locally with automatic model preparation.",
                    badge: "Local",
                    metadata: ollamaModel,
                    isSelected: llmProvider == .ollama,
                    isMuted: false,
                    actionTitle: llmProvider == .ollama ? "Selected" : "Use Local"
                ),
                StudioModelCard(
                    id: "openai-compatible",
                    name: "OpenAI-Compatible",
                    summary: "Use remote chat endpoints for persona rewriting and editing.",
                    badge: "Remote",
                    metadata: llmModel.isEmpty ? "Model not set" : llmModel,
                    isSelected: llmProvider == .openAICompatible,
                    isMuted: false,
                    actionTitle: llmProvider == .openAICompatible ? "Selected" : "Use Remote"
                )
            ]
        }
    }

    var currentArchitectureTitle: String {
        switch modelDomain {
        case .stt:
            switch sttProvider {
            case .appleSpeech, .localModel:
                return "Local Processing"
            case .freeModel, .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime:
                return "Remote API"
            }
        case .llm:
            return llmProvider == .ollama ? "Local Processing" : "Remote API"
        }
    }

    var currentArchitectureDescription: String {
        switch modelDomain {
        case .stt:
            switch sttProvider {
            case .freeModel:
                return "Using a code-configured free speech-to-text endpoint."
            case .appleSpeech:
                return "Using on-device speech recognition."
            case .localModel:
                return "Using a local Python-backed speech model."
            case .whisperAPI:
                return "Using OpenAI-compatible transcription services."
            case .multimodalLLM:
                return "Using a multimodal LLM for transcription and persona rewriting in one call."
            case .aliCloud:
                return "Streaming audio to Alibaba Cloud DashScope for real-time speech recognition."
            case .doubaoRealtime:
                return "Streaming audio to Doubao Speech Recognition 2.0 over WebSocket."
            }
        case .llm:
            return llmProvider == .ollama ? "Using local Ollama generation." : "Using remote chat-completion endpoints."
        }
    }

    func navigate(to section: StudioSection) {
        currentSection = section
        searchQuery = ""
        if section == .home || section == .history {
            applyHistoryRetentionPolicy()
            refreshHistory(reset: true)
        }
    }

    func refreshHistory(reset: Bool = true) {
        if reset {
            historyRecords = []
            displayedHistory = []
            canLoadMoreHistory = false
        }

        let records = historyStore.list(
            limit: Self.historyPageSize,
            offset: 0,
            searchQuery: historySearchQuery
        )
        historyRecords = records
        displayedHistory = records.map(makeHistoryPresentation)
        canLoadMoreHistory = records.count == Self.historyPageSize
        isLoadingMoreHistory = false
    }

    func loadMoreHistoryIfNeeded() {
        guard !isLoadingMoreHistory, canLoadMoreHistory else { return }

        isLoadingMoreHistory = true
        let nextPage = historyStore.list(
            limit: Self.historyPageSize,
            offset: historyRecords.count,
            searchQuery: historySearchQuery
        )

        if nextPage.isEmpty {
            canLoadMoreHistory = false
        } else {
            historyRecords.append(contentsOf: nextPage)
            displayedHistory.append(contentsOf: nextPage.map(makeHistoryPresentation))
            canLoadMoreHistory = nextPage.count == Self.historyPageSize
        }

        isLoadingMoreHistory = false
    }

    func refreshHistoryWithFeedback() {
        guard !isRefreshingHistory else { return }

        isRefreshingHistory = true

        Task {
            let startedAt = ContinuousClock.now
            refreshHistory()

            let elapsed = startedAt.duration(to: .now)
            let minimumFeedback = Duration.milliseconds(450)
            if elapsed < minimumFeedback {
                try? await Task.sleep(for: minimumFeedback - elapsed)
            }

            isRefreshingHistory = false
            showToast(L("history.toast.refreshed"))
        }
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        settingsStore.appearanceMode = mode
    }

    func setAppLanguage(_ language: AppLanguage) {
        appLanguage = language
        settingsStore.appLanguage = language
        AppLocalization.shared.setLanguage(language)
        refreshPermissionRows()
    }

    func refreshAvailableMicrophones() {
        let devices = audioDeviceManager.availableInputDevices()
        availableMicrophones = devices

        if !preferredMicrophoneID.isEmpty,
           devices.contains(where: { $0.id == preferredMicrophoneID }) == false {
            preferredMicrophoneID = AudioDeviceManager.automaticDeviceID
            settingsStore.preferredMicrophoneID = AudioDeviceManager.automaticDeviceID
            showToast(L("settings.audio.microphone.unavailable"))
        }
    }

    func setPreferredMicrophoneID(_ id: String) {
        preferredMicrophoneID = id
        settingsStore.preferredMicrophoneID = id
    }

    func setMuteSystemOutputDuringRecording(_ value: Bool) {
        muteSystemOutputDuringRecording = value
        settingsStore.muteSystemOutputDuringRecording = value
    }

    func setSoundEffectsEnabled(_ value: Bool) {
        soundEffectsEnabled = value
        settingsStore.soundEffectsEnabled = value
    }

    func setHistoryRetentionPolicy(_ value: HistoryRetentionPolicy) {
        historyRetentionPolicy = value
        settingsStore.historyRetentionPolicy = value
        applyHistoryRetentionPolicy()
        refreshHistory(reset: true)
        showToast(L("history.toast.retentionUpdated"))
    }

    func setSTTProvider(_ provider: STTProvider) {
        sttProvider = provider
        settingsStore.sttProvider = provider
        switch provider {
        case .freeModel:
            focusedModelProvider = .freeSTT
        case .appleSpeech:
            focusedModelProvider = .appleSpeech
        case .localModel:
            focusedModelProvider = .localSTT
            settingsStore.localSTTAutoSetup = true
            localSTTAutoSetup = true
            if !isLocalSTTPrepared && !isPreparingLocalSTT {
                prepareLocalSTTModel()
            }
        case .whisperAPI:
            focusedModelProvider = .whisperAPI
        case .multimodalLLM:
            focusedModelProvider = .multimodalLLM
        case .aliCloud:
            focusedModelProvider = .aliCloud
        case .doubaoRealtime:
            focusedModelProvider = .doubaoRealtime
        }
    }

    func setLLMProvider(_ provider: LLMProvider) {
        llmProvider = provider
        settingsStore.llmProvider = provider
        focusedModelProvider = provider == .ollama ? .ollama : llmRemoteProvider.studioProviderID
    }

    func setLLMRemoteProvider(_ provider: LLMRemoteProvider) {
        llmRemoteProvider = provider
        settingsStore.llmRemoteProvider = provider
        llmProvider = .openAICompatible
        settingsStore.llmProvider = .openAICompatible
        loadLLMConfiguration(for: provider)
        focusedModelProvider = provider.studioProviderID
    }

    func setSTTModelSelection(_ provider: STTProvider, suggestedModel: String) {
        setSTTProvider(provider)
        if provider == .freeModel {
            freeSTTModel = suggestedModel
            settingsStore.freeSTTModel = suggestedModel
        } else if provider == .whisperAPI {
            whisperModel = suggestedModel
            settingsStore.whisperModel = suggestedModel
        } else if provider == .multimodalLLM {
            multimodalLLMModel = suggestedModel
            settingsStore.multimodalLLMModel = suggestedModel
        }
    }

    func setLocalSTTModel(_ value: LocalSTTModel) {
        localSTTModel = value
        settingsStore.localSTTModel = value

        let recommendedIdentifier = value.defaultModelIdentifier
        localSTTModelIdentifier = recommendedIdentifier
        settingsStore.localSTTModelIdentifier = recommendedIdentifier

        let recommendedSource = value.recommendedDownloadSource
        localSTTDownloadSource = recommendedSource
        settingsStore.localSTTDownloadSource = recommendedSource
        localSTTAutoSetup = true
        settingsStore.localSTTAutoSetup = true
        refreshLocalSTTStoragePath()
        refreshLocalSTTPreparedState()
    }

    func setLLMModelSelection(_ provider: LLMProvider, suggestedModel: String) {
        setLLMProvider(provider)
        switch provider {
        case .ollama:
            ollamaModel = suggestedModel
            settingsStore.ollamaModel = suggestedModel
        case .openAICompatible:
            llmModel = suggestedModel
            settingsStore.setLLMModel(suggestedModel, for: llmRemoteProvider)
        }
    }

    func loadLLMConfiguration(for provider: LLMRemoteProvider) {
        llmBaseURL = settingsStore.llmBaseURL(for: provider)
        llmModel = settingsStore.llmModel(for: provider)
        llmAPIKey = settingsStore.llmAPIKey(for: provider)
    }

    func setModelDomain(_ domain: StudioModelDomain) {
        modelDomain = domain
        focusedModelProvider = activeProvider(for: domain)
    }

    func focusModelProvider(_ provider: StudioModelProviderID) {
        guard provider.domain == modelDomain else { return }
        focusedModelProvider = provider
        if let remoteProvider = LLMRemoteProvider.from(providerID: provider) {
            loadLLMConfiguration(for: remoteProvider)
        }
        llmTestTask?.cancel()
        sttTestTask?.cancel()
        llmConnectionTestState = .idle
        sttConnectionTestState = .idle
    }

    func setLLMBaseURL(_ value: String) { llmBaseURL = value; llmConnectionTestState = .idle }
    func setLLMModel(_ value: String) { llmModel = value; llmConnectionTestState = .idle }
    func setLLMAPIKey(_ value: String) { llmAPIKey = value; llmConnectionTestState = .idle }
    func setOllamaBaseURL(_ value: String) { ollamaBaseURL = value; llmConnectionTestState = .idle }
    func setOllamaModel(_ value: String) { ollamaModel = value; llmConnectionTestState = .idle }
    func setOllamaAutoSetup(_ value: Bool) { ollamaAutoSetup = value; settingsStore.ollamaAutoSetup = value }
    func setWhisperBaseURL(_ value: String) { whisperBaseURL = value; sttConnectionTestState = .idle }
    func setWhisperModel(_ value: String) { whisperModel = value; sttConnectionTestState = .idle }
    func setWhisperAPIKey(_ value: String) { whisperAPIKey = value; sttConnectionTestState = .idle }
    func setFreeSTTModel(_ value: String) { freeSTTModel = value; sttConnectionTestState = .idle }
    func setMultimodalLLMBaseURL(_ value: String) { multimodalLLMBaseURL = value; sttConnectionTestState = .idle }
    func setMultimodalLLMModel(_ value: String) { multimodalLLMModel = value; sttConnectionTestState = .idle }
    func setMultimodalLLMAPIKey(_ value: String) { multimodalLLMAPIKey = value; sttConnectionTestState = .idle }
    func setAliCloudAPIKey(_ value: String) { aliCloudAPIKey = value; sttConnectionTestState = .idle }
    func setDoubaoAppID(_ value: String) { doubaoAppID = value; sttConnectionTestState = .idle }
    func setDoubaoAccessToken(_ value: String) { doubaoAccessToken = value; sttConnectionTestState = .idle }
    func setDoubaoResourceID(_ value: String) { doubaoResourceID = value; sttConnectionTestState = .idle }
    func setLocalSTTModelIdentifier(_ value: String) {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localSTTModel.defaultModelIdentifier
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
        localSTTModelIdentifier = identifier
        settingsStore.localSTTModelIdentifier = identifier
        refreshLocalSTTStoragePath()
        refreshLocalSTTPreparedState()
    }
    func setLocalSTTDownloadSource(_ value: ModelDownloadSource) { localSTTDownloadSource = value; settingsStore.localSTTDownloadSource = value }
    func setLocalSTTAutoSetup(_ value: Bool) { localSTTAutoSetup = value; settingsStore.localSTTAutoSetup = value }
    func setAppleSpeechFallback(_ value: Bool) { appleSpeechFallback = value; settingsStore.useAppleSpeechFallback = value }
    func setAutomaticVocabularyCollectionEnabled(_ value: Bool) {
        automaticVocabularyCollectionEnabled = value
        settingsStore.automaticVocabularyCollectionEnabled = value
    }

    // MARK: - Agent Framework

    func setAgentFrameworkEnabled(_ value: Bool) {
        agentFrameworkEnabled = value
        settingsStore.agentFrameworkEnabled = value
    }

    func setAgentStepLoggingEnabled(_ value: Bool) {
        agentStepLoggingEnabled = value
        settingsStore.agentStepLoggingEnabled = value
    }

    func removeMCPServer(id: UUID) {
        mcpServers.removeAll { $0.id == id }
        settingsStore.mcpServers = mcpServers
    }

    func updateMCPServerEnabled(id: UUID, enabled: Bool) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        mcpServers[idx].enabled = enabled
        settingsStore.mcpServers = mcpServers
    }

    var canSaveMCPDraft: Bool {
        let nameValid = !mcpDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mcpDraftTransportType {
        case .stdio:
            return nameValid && !mcpDraftStdioCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .http:
            return nameValid && !mcpDraftHTTPURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func beginAddMCPServer() {
        mcpDraftEditingServerID = nil
        mcpDraftName = ""
        mcpDraftTransportType = .stdio
        mcpDraftStdioCommand = ""
        mcpDraftStdioArgs = ""
        mcpDraftStdioEnv = ""
        mcpDraftHTTPURL = ""
        mcpDraftHTTPHeaders = ""
        mcpDraftEnabled = true
        mcpDraftAutoConnect = false
        mcpConnectionTestTargetServerID = nil
        mcpConnectionTestState = .idle
    }

    func beginEditMCPServer(_ server: MCPServerConfig) {
        mcpDraftEditingServerID = server.id
        mcpDraftName = server.name
        mcpDraftEnabled = server.enabled
        mcpDraftAutoConnect = server.autoConnect
        mcpConnectionTestTargetServerID = nil
        mcpConnectionTestState = .idle
        switch server.transport {
        case .stdio(let config):
            mcpDraftTransportType = .stdio
            mcpDraftStdioCommand = config.command
            mcpDraftStdioArgs = config.args.joined(separator: " ")
            mcpDraftStdioEnv = config.env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            mcpDraftHTTPURL = ""
            mcpDraftHTTPHeaders = ""
        case .http(let config):
            mcpDraftTransportType = .http
            mcpDraftStdioCommand = ""
            mcpDraftStdioArgs = ""
            mcpDraftStdioEnv = ""
            mcpDraftHTTPURL = config.url
            mcpDraftHTTPHeaders = config.headers.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    func saveMCPDraft() {
        let transport: MCPTransportConfig
        switch mcpDraftTransportType {
        case .stdio:
            let envDict = parseMCPEnvString(mcpDraftStdioEnv)
            transport = .stdio(MCPStdioTransportConfig(
                command: mcpDraftStdioCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                args: mcpDraftStdioArgs.split(separator: " ").map(String.init),
                env: envDict
            ))
        case .http:
            let headersDict = parseMCPEnvString(mcpDraftHTTPHeaders)
            transport = .http(MCPHTTPTransportConfig(
                url: mcpDraftHTTPURL.trimmingCharacters(in: .whitespacesAndNewlines),
                headers: headersDict
            ))
        }

        if let editingID = mcpDraftEditingServerID,
           let idx = mcpServers.firstIndex(where: { $0.id == editingID }) {
            mcpServers[idx].name = mcpDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
            mcpServers[idx].transport = transport
            mcpServers[idx].enabled = mcpDraftEnabled
            mcpServers[idx].autoConnect = mcpDraftAutoConnect
        } else {
            let server = MCPServerConfig(
                name: mcpDraftName.trimmingCharacters(in: .whitespacesAndNewlines),
                transport: transport,
                enabled: mcpDraftEnabled,
                autoConnect: mcpDraftAutoConnect
            )
            mcpServers.append(server)
        }
        settingsStore.mcpServers = mcpServers
    }

    private func parseMCPEnvString(_ envString: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in envString.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result[key] = value }
            }
        }
        return result
    }

    func testMCPConnection(for server: MCPServerConfig) {
        mcpConnectionTestTargetServerID = server.id
        testMCPConnectionWithConfig(server.transport)
    }

    func testMCPDraftConnection() {
        mcpConnectionTestTargetServerID = nil
        let transport: MCPTransportConfig
        switch mcpDraftTransportType {
        case .stdio:
            let envDict = parseMCPEnvString(mcpDraftStdioEnv)
            transport = .stdio(MCPStdioTransportConfig(
                command: mcpDraftStdioCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                args: mcpDraftStdioArgs.split(separator: " ").map(String.init),
                env: envDict
            ))
        case .http:
            let headersDict = parseMCPEnvString(mcpDraftHTTPHeaders)
            transport = .http(MCPHTTPTransportConfig(
                url: mcpDraftHTTPURL.trimmingCharacters(in: .whitespacesAndNewlines),
                headers: headersDict
            ))
        }
        testMCPConnectionWithConfig(transport)
    }

    func isTestingMCPServer(_ serverID: UUID) -> Bool {
        mcpConnectionTestTargetServerID == serverID && mcpConnectionTestState == .testing
    }

    func shouldShowMCPConnectionTestResult(for serverID: UUID) -> Bool {
        mcpConnectionTestTargetServerID == serverID && mcpConnectionTestState != .idle
    }

    private func testMCPConnectionWithConfig(_ transport: MCPTransportConfig) {
        mcpTestTask?.cancel()
        mcpConnectionTestState = .testing
        mcpTestTask = Task {
            do {
                let client: any MCPClient
                switch transport {
                case .stdio(let config):
                    client = StdioMCPClient(config: MCPStdioConfig(
                        command: config.command, args: config.args, env: config.env
                    ))
                case .http(let config):
                    guard let url = URL(string: config.url) else {
                        if !Task.isCancelled {
                            mcpConnectionTestState = .failure(message: "Invalid URL")
                        }
                        return
                    }
                    client = HTTPMCPClient(config: MCPHTTPConfig(url: url, headers: config.headers))
                }
                try await client.connect()
                let tools = try await client.listTools()
                await client.disconnect()

                if !Task.isCancelled {
                    let discoveredTools = tools.map {
                        MCPConnectionTestState.MCPDiscoveredTool(
                            id: $0.name,
                            name: $0.name,
                            description: $0.description ?? ""
                        )
                    }
                    mcpConnectionTestState = .success(tools: discoveredTools)
                }
            } catch {
                if !Task.isCancelled {
                    mcpConnectionTestState = .failure(message: error.localizedDescription)
                }
            }
        }
    }

    func setLaunchAtLogin(_ value: Bool) { launchAtLogin = value; LaunchAtLoginManager.setEnabled(value) }
    func setPersonaRewriteEnabled(_ value: Bool) {
        personaRewriteEnabled = value
        settingsStore.personaRewriteEnabled = value
    }
    func setPersonaHotkeyAppliesToSelection(_ value: Bool) {
        personaHotkeyAppliesToSelection = value
        settingsStore.personaHotkeyAppliesToSelection = value
    }

    var defaultPersonaSelectionID: UUID? {
        guard personaRewriteEnabled else { return nil }
        return UUID(uuidString: activePersonaID) ?? selectedPersonaID
    }

    func setDefaultPersonaSelection(_ id: UUID?) {
        guard let id else {
            setPersonaRewriteEnabled(false)
            return
        }

        settingsStore.activePersonaID = id.uuidString
        activePersonaID = id.uuidString
        selectedPersonaID = id

        if !personaRewriteEnabled {
            setPersonaRewriteEnabled(true)
        }
    }

    func selectPersona(_ id: UUID?) {
        selectedPersonaID = id
        if settingsStore.activePersonaID.isEmpty, let id {
            settingsStore.activePersonaID = id.uuidString
            activePersonaID = id.uuidString
        }
        loadPersonaDraft()
    }

    func setActivationHotkey(_ binding: HotkeyBinding) {
        guard binding.signature != personaHotkey.signature,
              binding.signature != askHotkey.signature else {
            showToast(L("settings.shortcuts.activationConflict"))
            return
        }

        activationHotkey = binding
        settingsStore.activationHotkey = binding
        showToast(L("settings.shortcuts.activationUpdated"))
    }

    func resetActivationHotkey() {
        setActivationHotkey(.defaultActivation)
    }

    func setAskHotkey(_ binding: HotkeyBinding) {
        guard binding.signature != activationHotkey.signature,
              binding.signature != personaHotkey.signature else {
            showToast(L("settings.shortcuts.askConflict"))
            return
        }

        askHotkey = binding
        settingsStore.askHotkey = binding
        showToast(L("settings.shortcuts.askUpdated"))
    }

    func resetAskHotkey() {
        setAskHotkey(.defaultAsk)
    }

    func setPersonaHotkey(_ binding: HotkeyBinding) {
        guard binding.signature != activationHotkey.signature,
              binding.signature != askHotkey.signature else {
            showToast(L("settings.shortcuts.personaConflict"))
            return
        }

        personaHotkey = binding
        settingsStore.personaHotkey = binding
        showToast(L("settings.shortcuts.personaUpdated"))
    }

    func resetPersonaHotkey() {
        setPersonaHotkey(.defaultPersona)
    }

    func applyPersonaSelection(_ id: UUID?) {
        settingsStore.applyPersonaSelection(id)
        syncPersonaSelectionFromStore()

        if let id, let persona = personas.first(where: { $0.id == id }) {
            showToast(L("workflow.persona.switched", persona.name))
        } else {
            showToast(L("workflow.persona.disabled"))
        }
    }

    func addVocabularyTerm(_ term: String, source: VocabularySource = .manual) {
        vocabularyEntries = VocabularyStore.add(term: term, source: source)
    }

    func removeVocabularyEntry(id: UUID) {
        vocabularyEntries = VocabularyStore.remove(id: id)
    }

    func beginCreatingPersona() {
        isCreatingPersonaDraft = true
        selectedPersonaID = nil
        personaDraftName = ""
        personaDraftPrompt = ""
    }

    func deletePersona(id: UUID) {
        guard let persona = personas.first(where: { $0.id == id }), !persona.isSystem else { return }
        personas.removeAll { $0.id == id }
        persistPersonas()
        if settingsStore.activePersonaID == id.uuidString {
            settingsStore.activePersonaID = personas.first?.id.uuidString ?? ""
            activePersonaID = settingsStore.activePersonaID
        }
        if selectedPersonaID == id {
            selectedPersonaID = personas.first?.id
        }
        isCreatingPersonaDraft = false
        loadPersonaDraft()
    }

    func activateSelectedPersona() {
        guard let selectedPersona else { return }
        settingsStore.applyPersonaSelection(selectedPersona.id)
        syncPersonaSelectionFromStore()
    }

    func deactivatePersonaRewrite() {
        settingsStore.applyPersonaSelection(nil)
        syncPersonaSelectionFromStore()
    }

    func savePersonaDraft() {
        let name = personaDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = personaDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if isCreatingPersonaDraft {
            let persona = PersonaProfile(name: name, prompt: prompt)
            personas.insert(persona, at: 0)
            persistPersonas()
            selectedPersonaID = persona.id
            isCreatingPersonaDraft = false
            if settingsStore.activePersonaID.isEmpty {
                settingsStore.activePersonaID = persona.id.uuidString
                activePersonaID = persona.id.uuidString
            }
            loadPersonaDraft()
            showToast(L("settings.personas.saved"))
            return
        }

        guard let selectedPersonaID, let index = personas.firstIndex(where: { $0.id == selectedPersonaID }) else { return }
        guard !personas[index].isSystem else { return }
        personas[index].name = name
        personas[index].prompt = prompt
        persistPersonas()
        loadPersonaDraft()
        showToast(L("settings.personas.saved"))
    }

    private func syncPersonaSelectionFromStore() {
        personaRewriteEnabled = settingsStore.personaRewriteEnabled
        personaHotkeyAppliesToSelection = settingsStore.personaHotkeyAppliesToSelection
        activePersonaID = settingsStore.activePersonaID
        selectedPersonaID = settingsStore.activePersona.map(\.id) ?? selectedPersonaID
        if !isCreatingPersonaDraft {
            loadPersonaDraft()
        }
    }

    func cancelPersonaEditing() {
        if isCreatingPersonaDraft {
            isCreatingPersonaDraft = false
            selectedPersonaID = personas.first?.id
        }
        loadPersonaDraft()
    }

    func prepareOllamaModel() {
        guard !isPreparingOllama else { return }

        isPreparingOllama = true
        ollamaStatus = L("settings.models.ollama.preparing")

        settingsStore.ollamaBaseURL = ollamaBaseURL
        settingsStore.ollamaModel = ollamaModel
        settingsStore.ollamaAutoSetup = ollamaAutoSetup

        Task {
            do {
                try await modelManager.ensureModelReady(settingsStore: settingsStore)
                ollamaStatus = L("settings.models.ollama.ready")
                showToast(L("settings.models.ollama.ready"))
            } catch {
                ollamaStatus = L("common.failedWithReason", error.localizedDescription)
                showToast(L("settings.models.ollama.prepareFailed"))
            }
            isPreparingOllama = false
        }
    }

    func prepareLocalSTTModel() {
        guard !isPreparingLocalSTT else { return }

        setLocalSTTModelIdentifier(localSTTModel.defaultModelIdentifier)
        localSTTAutoSetup = true
        settingsStore.localSTTAutoSetup = true

        if localSTTServiceManager.preparedModelInfo(settingsStore: settingsStore) != nil {
            refreshLocalSTTPreparedState()
            showToast(L("settings.models.localSTT.ready"))
            return
        }

        isPreparingLocalSTT = true
        localSTTStatus = L("settings.models.localSTT.preparing")
        localSTTPreparationProgress = 0.02
        localSTTPreparationDetail = L("settings.models.localSTT.preparing")
        isLocalSTTPrepared = false
        localSTTPreparedSource = L("common.automatic")
        refreshLocalSTTStoragePath()

        settingsStore.localSTTModel = localSTTModel
        settingsStore.localSTTModelIdentifier = localSTTModelIdentifier
        settingsStore.localSTTDownloadSource = localSTTDownloadSource
        settingsStore.localSTTAutoSetup = localSTTAutoSetup

        Task {
            do {
                try await localSTTServiceManager.prepareModel(settingsStore: settingsStore) { [weak self] update in
                    Task { @MainActor in
                        self?.localSTTPreparationProgress = update.progress
                        self?.localSTTPreparationDetail = update.message
                        self?.localSTTStoragePath = update.storagePath
                        if let source = update.source {
                            self?.localSTTPreparedSource = source
                        }
                    }
                }
                localSTTStatus = L("settings.models.localSTT.readyNamed", localSTTModel.displayName)
                localSTTPreparationProgress = 1
                localSTTPreparationDetail = L("settings.models.localSTT.downloadComplete")
                isLocalSTTPrepared = true
                refreshLocalSTTPreparedState()
                showToast(L("settings.models.localSTT.ready"))
            } catch {
                localSTTStatus = L("common.failedWithReason", error.localizedDescription)
                localSTTPreparationDetail = L("settings.models.localSTT.prepareFailed")
                isLocalSTTPrepared = false
                showToast(L("settings.models.localSTT.prepareFailed"))
            }
            isPreparingLocalSTT = false
        }
    }

    func isModelDownloaded(_ model: LocalSTTModel) -> Bool {
        localSTTServiceManager.isModelDownloaded(model)
    }

    func deleteLocalSTTModel(_ model: LocalSTTModel) {
        do {
            try localSTTServiceManager.deleteModelFiles(model)
            if model == localSTTModel {
                isLocalSTTPrepared = false
                localSTTPreparationProgress = 0
                localSTTStatus = L("settings.models.localSTT.notPrepared")
                localSTTPreparationDetail = L("settings.models.localSTT.autoPrepareHint")
            }
            showToast(L("settings.models.localSTT.deleted"))
        } catch {
            showToast(L("common.failedWithReason", error.localizedDescription))
        }
    }

    func redownloadLocalSTTModel(_ model: LocalSTTModel) {
        try? localSTTServiceManager.deleteModelFiles(model)
        if localSTTModel != model {
            setLocalSTTModel(model)
        } else {
            isLocalSTTPrepared = false
            localSTTPreparationProgress = 0
        }
        prepareLocalSTTModel()
    }

    func exportHistory() {
        do {
            let url = try historyStore.exportMarkdown()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showToast(L("history.toast.exported"))
        } catch {
            showToast(L("history.toast.exportFailed"))
        }
    }

    func clearHistory() {
        historyStore.clear()
        historyRecords = []
        displayedHistory = []
        canLoadMoreHistory = false
        showToast(L("history.toast.cleared"))
    }

    func retryHistoryRecord(id: UUID) {
        guard let record = historyRecords.first(where: { $0.id == id }) else { return }
        onRetryHistory(record)
        showToast(L("history.toast.retryStarted"))
    }

    func copyTranscript(id: UUID) {
        guard
            let record = historyRecords.first(where: { $0.id == id }),
            let transcriptText = record.transcriptText,
            !transcriptText.isEmpty
        else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
        showToast(L("history.toast.transcriptCopied"))
    }

    func downloadAudio(id: UUID) {
        guard
            let record = historyRecords.first(where: { $0.id == id }),
            let audioFilePath = record.audioFilePath,
            !audioFilePath.isEmpty
        else { return }

        let sourceURL = URL(fileURLWithPath: audioFilePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            showToast(L("history.toast.audioUnavailable"))
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let destinationURL = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                showToast(L("history.toast.audioDownloaded"))
            } catch {
                showToast(L("history.toast.audioDownloadFailed"))
            }
        }
    }

    func deleteHistoryRecord(id: UUID) {
        historyStore.delete(id: id)
        historyRecords.removeAll { $0.id == id }
        displayedHistory.removeAll { $0.id == id }
        showToast(L("history.toast.transcriptDeleted"))
    }

    func applyModelConfiguration(shouldShowToast: Bool = true) {
        switch focusedModelProvider {
        case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax:
            let remoteProvider = LLMRemoteProvider.from(providerID: focusedModelProvider) ?? llmRemoteProvider
            settingsStore.setLLMBaseURL(llmBaseURL, for: remoteProvider)
            settingsStore.setLLMModel(llmModel, for: remoteProvider)
            settingsStore.setLLMAPIKey(remoteProvider == .freeModel ? "" : llmAPIKey, for: remoteProvider)
            if llmProvider == .openAICompatible && llmRemoteProvider == remoteProvider {
                settingsStore.llmRemoteProvider = remoteProvider
            }
        case .ollama:
            settingsStore.ollamaBaseURL = ollamaBaseURL
            settingsStore.ollamaModel = ollamaModel
        case .freeSTT:
            settingsStore.freeSTTModel = freeSTTModel
        case .whisperAPI:
            settingsStore.whisperBaseURL = whisperBaseURL
            settingsStore.whisperModel = whisperModel
            settingsStore.whisperAPIKey = whisperAPIKey
        case .multimodalLLM:
            settingsStore.multimodalLLMBaseURL = multimodalLLMBaseURL
            settingsStore.multimodalLLMModel = multimodalLLMModel
            settingsStore.multimodalLLMAPIKey = multimodalLLMAPIKey
        case .aliCloud:
            settingsStore.aliCloudAPIKey = aliCloudAPIKey
        case .doubaoRealtime:
            settingsStore.doubaoAppID = doubaoAppID
            settingsStore.doubaoAccessToken = doubaoAccessToken
            settingsStore.doubaoResourceID = doubaoResourceID
        case .appleSpeech, .localSTT:
            break
        }
        if shouldShowToast {
            showToast(L("settings.models.configurationSaved"))
        }
    }

    func focusedLLMProviderMissingAPIKey() -> Bool {
        guard focusedModelProvider.domain == .llm else { return false }
        guard focusedModelProvider != .ollama else { return false }
        guard focusedModelProvider != .freeModel else { return false }
        return llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func testLLMConnection() {
        llmTestTask?.cancel()
        llmConnectionTestState = .testing

        let capturedProvider = focusedModelProvider
        let capturedRemoteProvider = LLMRemoteProvider.from(providerID: capturedProvider) ?? llmRemoteProvider
        let capturedBaseURL = llmBaseURL
        let capturedModel = llmModel
        let capturedAPIKey = llmAPIKey
        let capturedOllamaURL = ollamaBaseURL.isEmpty ? "http://127.0.0.1:11434" : ollamaBaseURL
        let capturedOllamaModel = ollamaModel

        llmTestTask = Task {
            let startDate = Date()
            var firstTokenDate: Date? = nil
            var collected = ""

            do {
                switch capturedProvider {
                case .freeSTT:
                    return
                case .freeModel, .customLLM, .openRouter, .openAI, .anthropic, .gemini, .deepSeek, .kimi, .qwen, .zhipu, .minimax:
                    let connection = try LLMConnectionResolver.resolve(
                        provider: capturedRemoteProvider,
                        baseURL: capturedBaseURL,
                        model: capturedModel,
                        apiKey: capturedAPIKey
                    )
                    let preview = try await RemoteLLMClient.previewConnection(
                        provider: connection.provider,
                        baseURL: connection.baseURL,
                        model: connection.model,
                        apiKey: connection.apiKey,
                        additionalHeaders: connection.additionalHeaders
                    )
                    if !preview.isEmpty {
                        firstTokenDate = Date()
                    }
                    collected = preview

                case .ollama:
                    guard let baseURL = URL(string: capturedOllamaURL) else {
                        throw NSError(domain: "LLMTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama base URL."])
                    }
                    let url = baseURL.appendingPathComponent("api/chat")
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": capturedOllamaModel,
                        "stream": true,
                        "messages": [["role": "user", "content": "Hello"]],
                        "options": ["num_predict": 50]
                    ]
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw NSError(domain: "LLMTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response."])
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        throw NSError(domain: "LLMTest", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(message)"])
                    }

                    struct OllamaTestResponse: Decodable {
                        struct Message: Decodable { let content: String? }
                        let message: Message?
                        let done: Bool
                    }

                    var lineBuffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { return }
                        lineBuffer.append(byte)
                        guard byte == 0x0A else { continue }
                        let lineStr = String(data: lineBuffer, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
                        lineBuffer = Data()
                        guard !lineStr.isEmpty,
                              let lineData = lineStr.data(using: .utf8),
                              let payload = try? JSONDecoder().decode(OllamaTestResponse.self, from: lineData)
                        else { continue }
                        if let content = payload.message?.content, !content.isEmpty {
                            if firstTokenDate == nil { firstTokenDate = Date() }
                            collected += content
                        }
                        if payload.done || collected.count >= 60 { break }
                    }
                case .appleSpeech, .localSTT, .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime:
                    return
                }

                if Task.isCancelled { return }
                let totalMs = Int(Date().timeIntervalSince(startDate) * 1000)
                let firstMs = firstTokenDate.map { Int($0.timeIntervalSince(startDate) * 1000) } ?? totalMs
                llmConnectionTestState = .success(
                    firstTokenMs: firstMs,
                    totalMs: totalMs,
                    preview: String(collected.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                )
            } catch {
                if !Task.isCancelled {
                    llmConnectionTestState = .failure(message: error.localizedDescription)
                }
            }
        }
    }

    func testSTTConnection() {
        sttTestTask?.cancel()
        sttConnectionTestState = .testing

        let capturedProvider = focusedModelProvider
        let capturedFreeSTTModel = freeSTTModel
        let capturedWhisperBaseURL = whisperBaseURL
        let capturedWhisperModel = whisperModel
        let capturedWhisperAPIKey = whisperAPIKey
        let capturedMultimodalBaseURL = multimodalLLMBaseURL
        let capturedMultimodalModel = multimodalLLMModel
        let capturedMultimodalAPIKey = multimodalLLMAPIKey
        let capturedAliCloudAPIKey = aliCloudAPIKey
        let capturedDoubaoAppID = doubaoAppID
        let capturedDoubaoAccessToken = doubaoAccessToken
        let capturedDoubaoResourceID = doubaoResourceID

        sttTestTask = Task {
            let startDate = Date()

            do {
                let preview: String
                switch capturedProvider {
                case .freeSTT:
                    preview = try await FreeSTTTranscriber.testConnection(modelName: capturedFreeSTTModel)
                case .whisperAPI:
                    preview = try await WhisperAPITranscriber.testConnection(
                        baseURL: capturedWhisperBaseURL,
                        model: capturedWhisperModel,
                        apiKey: capturedWhisperAPIKey
                    )
                case .multimodalLLM:
                    preview = try await MultimodalLLMTranscriber.testConnection(
                        baseURL: capturedMultimodalBaseURL,
                        model: capturedMultimodalModel,
                        apiKey: capturedMultimodalAPIKey
                    )
                case .aliCloud:
                    preview = try await AliCloudRealtimeTranscriber.testConnection(apiKey: capturedAliCloudAPIKey)
                case .doubaoRealtime:
                    preview = try await DoubaoRealtimeTranscriber.testConnection(
                        appID: capturedDoubaoAppID,
                        accessToken: capturedDoubaoAccessToken,
                        resourceID: capturedDoubaoResourceID
                    )
                default:
                    return
                }

                if Task.isCancelled { return }
                let totalMs = Int(Date().timeIntervalSince(startDate) * 1000)
                sttConnectionTestState = .success(
                    firstTokenMs: totalMs,
                    totalMs: totalMs,
                    preview: String(preview.prefix(120))
                )
            } catch {
                if !Task.isCancelled {
                    sttConnectionTestState = .failure(message: error.localizedDescription)
                }
            }
        }
    }

    func copyLocalSTTStoragePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localSTTStoragePath, forType: .string)
        showToast(L("settings.models.storagePathCopied"))
    }

    func openLocalSTTStorageFolder() {
        let storageURL = URL(fileURLWithPath: localSTTStoragePath)
        let targetURL = storageURL.hasDirectoryPath ? storageURL : storageURL.deletingLastPathComponent()
        NSWorkspace.shared.open(targetURL)
    }

    func dismissToast() {
        toastMessage = nil
    }

    func refreshPermissionRows() {
        permissionRows = PrivacyGuard.snapshots().map { snapshot in
            StudioPermissionRowModel(
                id: snapshot.id,
                title: snapshot.title,
                summary: snapshot.summary,
                detail: snapshot.detail,
                isGranted: snapshot.isGranted,
                badgeText: snapshot.badgeText,
                actionTitle: snapshot.actionTitle
            )
        }
    }

    func refreshPermissionRowsWithFeedback() {
        guard !isRefreshingPermissions else { return }

        isRefreshingPermissions = true

        Task {
            let startedAt = ContinuousClock.now
            refreshPermissionRows()

            let elapsed = startedAt.duration(to: .now)
            let minimumFeedback = Duration.milliseconds(450)
            if elapsed < minimumFeedback {
                try? await Task.sleep(for: minimumFeedback - elapsed)
            }

            isRefreshingPermissions = false
            showToast(L("settings.permissions.updated"))
        }
    }

    func schedulePermissionRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            refreshPermissionRows()
        }
    }

    func requestPermission(_ id: PrivacyGuard.PermissionID) {
        Task {
            await PrivacyGuard.requestPermission(id)
            try? await Task.sleep(nanoseconds: 350_000_000)
            refreshPermissionRows()
            if let row = permissionRows.first(where: { $0.id == id }) {
                showToast(row.isGranted ? L("settings.permissions.ready", row.title) : L("settings.permissions.reviewInSystemSettings", row.title))
            }
        }
    }

    private var historySearchQuery: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyHistoryRetentionPolicy() {
        guard let days = historyRetentionPolicy.days else { return }
        historyStore.purge(olderThanDays: days)
    }

    private func persistPersonas() {
        settingsStore.personas = personas
    }

    private func loadPersonaDraft() {
        if let selectedPersona {
            personaDraftName = selectedPersona.name
            personaDraftPrompt = selectedPersona.prompt
        } else {
            personaDraftName = ""
            personaDraftPrompt = ""
        }
    }

    private func activeProvider(for domain: StudioModelDomain) -> StudioModelProviderID {
        switch domain {
        case .stt:
            switch sttProvider {
            case .freeModel:
                return .freeSTT
            case .appleSpeech:
                return .appleSpeech
            case .localModel:
                return .localSTT
            case .whisperAPI:
                return .whisperAPI
            case .multimodalLLM:
                return .multimodalLLM
            case .aliCloud:
                return .aliCloud
            case .doubaoRealtime:
                return .doubaoRealtime
            }
        case .llm:
            return llmProvider == .ollama ? .ollama : llmRemoteProvider.studioProviderID
        }
    }

    private static func visibleSTTProvider(from provider: STTProvider) -> STTProvider {
        provider == .appleSpeech ? .whisperAPI : provider
    }

    private func showToast(_ text: String) {
        toastMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toastMessage == text {
                toastMessage = nil
            }
        }
    }

    private func refreshLocalSTTStoragePath() {
        let identifier = localSTTModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localSTTModel.defaultModelIdentifier
            : localSTTModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localSTTModel {
        case .whisperLocal:
            localSTTStoragePath = URL(fileURLWithPath: localSTTServiceManager.modelsRootPath)
                .appendingPathComponent("\(identifier).pt", isDirectory: false)
                .path
        case .senseVoiceSmall, .qwen3ASR:
            localSTTStoragePath = URL(fileURLWithPath: localSTTServiceManager.modelsRootPath)
                .appendingPathComponent(identifier.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
                .path
        }
    }

    private func refreshLocalSTTPreparedState() {
        if let prepared = localSTTServiceManager.preparedModelInfo(settingsStore: settingsStore) {
            isLocalSTTPrepared = true
            localSTTPreparedSource = prepared.sourceDisplayName
            localSTTStoragePath = prepared.storagePath
            localSTTStatus = "\(localSTTModel.displayName) is ready."
            localSTTPreparationDetail = "Download complete. Local speech model is ready."
            localSTTPreparationProgress = 1
        } else {
            isLocalSTTPrepared = false
            localSTTPreparedSource = "Automatic"
            localSTTStatus = "Local speech model has not been prepared yet."
            localSTTPreparationDetail = "The selected local speech model will be prepared automatically when needed."
            localSTTPreparationProgress = 0
        }
    }

    private func makeHistoryPresentation(_ record: HistoryRecord) -> HistoryPresentationRecord {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let fileName = record.audioFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No audio file"
        let preview = record.text.replacingOccurrences(of: "\n", with: " ")

        let fileExtension = record.audioFilePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let iconData: (String, String)
        switch fileExtension {
        case "wav":
            iconData = ("mic.fill", "purple")
        case "mp4":
            iconData = ("play.rectangle.fill", "green")
        case "m4a":
            iconData = ("waveform", "orange")
        default:
            iconData = ("doc.text.fill", "blue")
        }

        return HistoryPresentationRecord(
            id: record.id,
            date: record.date,
            timestampText: formatter.string(from: record.date),
            sourceName: fileName,
            previewText: "\(preview.prefix(84))\(preview.count > 84 ? "..." : "")",
            audioFilePath: record.audioFilePath,
            transcriptText: record.transcriptText,
            personaPrompt: record.personaPrompt,
            personaResultText: record.personaResultText,
            selectionOriginalText: record.selectionOriginalText,
            selectionEditedText: record.selectionEditedText,
            pipelineStatItems: historyPipelineStatItems(record.pipelineStats ?? record.pipelineTiming?.generatedStats()),
            errorMessage: record.errorMessage,
            applyMessage: record.applyMessage,
            hasTranscriptToCopy: !(record.transcriptText?.isEmpty ?? true),
            canRetry: record.audioFilePath.map { FileManager.default.fileExists(atPath: $0) } == true,
            hasFailure: record.hasFailure,
            failureMessage: record.errorMessage,
            accentName: iconData.0,
            accentColorName: iconData.1
        )
    }

    private func historyPipelineStatItems(_ stats: HistoryPipelineStats?) -> [HistoryPipelineStatPresentationItem] {
        guard let stats, stats.hasData else { return [] }

        let durationRows: [(String, Int?)] = [
            (L("history.stats.transcriptionDuration"), stats.transcriptionDurationMilliseconds),
            (L("history.stats.llmDuration"), stats.llmDurationMilliseconds),
            (L("history.stats.endToEnd"), stats.endToEndMilliseconds)
        ]

        return durationRows.enumerated().compactMap { item -> HistoryPipelineStatPresentationItem? in
            let index = item.offset
            let row = item.element
            guard let value = row.1 else { return nil }
            return HistoryPipelineStatPresentationItem(
                id: "duration-\(index)",
                title: row.0,
                value: historyDurationText(milliseconds: value),
                style: .duration
            )
        }
    }

    private func historyDurationText(milliseconds: Int) -> String {
        if milliseconds >= 1000 {
            return String(format: L("history.stats.durationSecondsFormat"), Double(milliseconds) / 1000.0)
        }

        return String(format: L("history.stats.durationMillisecondsFormat"), milliseconds)
    }
}
