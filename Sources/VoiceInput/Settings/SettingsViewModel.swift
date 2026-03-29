import AppKit
import Foundation
import SwiftUI

enum LLMConnectionTestState: Equatable {
    case idle
    case testing
    case success(firstTokenMs: Int, totalMs: Int, preview: String)
    case failure(message: String)
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
    @Published var appearanceMode: AppearanceMode
    @Published var availableMicrophones: [AudioInputDevice] = []
    @Published var preferredMicrophoneID: String
    @Published var muteSystemOutputDuringRecording: Bool

    @Published var llmBaseURL: String
    @Published var llmModel: String
    @Published var llmAPIKey: String

    @Published var ollamaBaseURL: String
    @Published var ollamaModel: String
    @Published var ollamaAutoSetup: Bool
    @Published var ollamaStatus = "Local model has not been prepared yet."
    @Published var isPreparingOllama = false

    @Published var whisperBaseURL: String
    @Published var whisperModel: String
    @Published var whisperAPIKey: String

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
    @Published var localSTTStatus = "Local speech model has not been prepared yet."
    @Published var localSTTPreparationProgress: Double = 0
    @Published var localSTTPreparationDetail = "The selected local speech model will be prepared automatically when needed."
    @Published var localSTTStoragePath: String
    @Published var localSTTPreparedSource = "Automatic"
    @Published var isLocalSTTPrepared = false
    @Published var isPreparingLocalSTT = false

    @Published var appleSpeechFallback: Bool

    @Published var personaRewriteEnabled: Bool
    @Published var personas: [PersonaProfile]
    @Published var selectedPersonaID: UUID?
    @Published private(set) var activePersonaID: String
    @Published var personaDraftName: String
    @Published var personaDraftPrompt: String
    @Published private(set) var isCreatingPersonaDraft: Bool
    @Published var vocabularyEntries: [VocabularyEntry]

    @Published var launchAtLogin: Bool
    @Published var activationHotkey: HotkeyBinding
    @Published var personaHotkey: HotkeyBinding
    @Published var historyRetentionPolicy: HistoryRetentionPolicy
    @Published private(set) var historyRecords: [HistoryRecord]
    @Published var toastMessage: String?
    @Published var llmConnectionTestState: LLMConnectionTestState = .idle
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
    private var llmTestTask: Task<Void, Never>?

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
        if initialSTTProvider != settingsStore.sttProvider {
            settingsStore.sttProvider = initialSTTProvider
        }
        sttProvider = initialSTTProvider
        llmProvider = settingsStore.llmProvider
        switch initialSTTProvider {
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
        preferredMicrophoneID = settingsStore.preferredMicrophoneID
        muteSystemOutputDuringRecording = settingsStore.muteSystemOutputDuringRecording
        llmBaseURL = settingsStore.llmBaseURL
        llmModel = settingsStore.llmModel
        llmAPIKey = settingsStore.llmAPIKey
        ollamaBaseURL = settingsStore.ollamaBaseURL
        ollamaModel = settingsStore.ollamaModel
        ollamaAutoSetup = settingsStore.ollamaAutoSetup
        whisperBaseURL = settingsStore.whisperBaseURL
        whisperModel = settingsStore.whisperModel
        whisperAPIKey = settingsStore.whisperAPIKey
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
        personaRewriteEnabled = settingsStore.personaRewriteEnabled
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
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
        if let personaSelectionObserver {
            NotificationCenter.default.removeObserver(personaSelectionObserver)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var localSTTPreparationPercentText: String {
        "\(Int((localSTTPreparationProgress * 100).rounded()))%"
    }

    var localSTTPreparationTint: Color {
        if isLocalSTTPrepared {
            return StudioTheme.success
        }

        if localSTTStatus.hasPrefix("Failed:") {
            return StudioTheme.danger
        }

        return StudioTheme.accent
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
                title = "Today"
            } else if calendar.isDateInYesterday(date) {
                title = "Yesterday"
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

    var hasPersonaDraftChanges: Bool {
        if isCreatingPersonaDraft {
            return !personaDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !personaDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard let selectedPersona else { return false }
        return personaDraftName != selectedPersona.name || personaDraftPrompt != selectedPersona.prompt
    }

    var canSavePersonaDraft: Bool {
        !personaDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            case .whisperAPI, .multimodalLLM, .aliCloud, .doubaoRealtime:
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
            showToast("History refreshed.")
        }
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        settingsStore.appearanceMode = mode
    }

    func refreshAvailableMicrophones() {
        let devices = audioDeviceManager.availableInputDevices()
        availableMicrophones = devices

        if !preferredMicrophoneID.isEmpty,
           devices.contains(where: { $0.id == preferredMicrophoneID }) == false {
            preferredMicrophoneID = AudioDeviceManager.automaticDeviceID
            settingsStore.preferredMicrophoneID = AudioDeviceManager.automaticDeviceID
            showToast("Selected microphone is unavailable. Switched to automatic.")
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

    func setHistoryRetentionPolicy(_ value: HistoryRetentionPolicy) {
        historyRetentionPolicy = value
        settingsStore.historyRetentionPolicy = value
        applyHistoryRetentionPolicy()
        refreshHistory(reset: true)
        showToast("History retention updated.")
    }

    func setSTTProvider(_ provider: STTProvider) {
        sttProvider = provider
        settingsStore.sttProvider = provider
        switch provider {
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
        focusedModelProvider = provider == .ollama ? .ollama : .openAICompatible
    }

    func setSTTModelSelection(_ provider: STTProvider, suggestedModel: String) {
        setSTTProvider(provider)
        if provider == .whisperAPI {
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
            settingsStore.llmModel = suggestedModel
        }
    }

    func setModelDomain(_ domain: StudioModelDomain) {
        modelDomain = domain
        focusedModelProvider = activeProvider(for: domain)
    }

    func focusModelProvider(_ provider: StudioModelProviderID) {
        guard provider.domain == modelDomain else { return }
        focusedModelProvider = provider
        llmTestTask?.cancel()
        llmConnectionTestState = .idle
    }

    func setLLMBaseURL(_ value: String) { llmBaseURL = value; llmConnectionTestState = .idle }
    func setLLMModel(_ value: String) { llmModel = value; llmConnectionTestState = .idle }
    func setLLMAPIKey(_ value: String) { llmAPIKey = value; llmConnectionTestState = .idle }
    func setOllamaBaseURL(_ value: String) { ollamaBaseURL = value; llmConnectionTestState = .idle }
    func setOllamaModel(_ value: String) { ollamaModel = value; llmConnectionTestState = .idle }
    func setOllamaAutoSetup(_ value: Bool) { ollamaAutoSetup = value; settingsStore.ollamaAutoSetup = value }
    func setWhisperBaseURL(_ value: String) { whisperBaseURL = value }
    func setWhisperModel(_ value: String) { whisperModel = value }
    func setWhisperAPIKey(_ value: String) { whisperAPIKey = value }
    func setMultimodalLLMBaseURL(_ value: String) { multimodalLLMBaseURL = value }
    func setMultimodalLLMModel(_ value: String) { multimodalLLMModel = value }
    func setMultimodalLLMAPIKey(_ value: String) { multimodalLLMAPIKey = value }
    func setAliCloudAPIKey(_ value: String) { aliCloudAPIKey = value }
    func setDoubaoAppID(_ value: String) { doubaoAppID = value }
    func setDoubaoAccessToken(_ value: String) { doubaoAccessToken = value }
    func setDoubaoResourceID(_ value: String) { doubaoResourceID = value }
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
    func setLaunchAtLogin(_ value: Bool) { launchAtLogin = value; LaunchAtLoginManager.setEnabled(value) }
    func setPersonaRewriteEnabled(_ value: Bool) {
        personaRewriteEnabled = value
        settingsStore.personaRewriteEnabled = value
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
        guard binding.signature != personaHotkey.signature else {
            showToast("Activation shortcut cannot match the persona shortcut.")
            return
        }

        activationHotkey = binding
        settingsStore.activationHotkey = binding
        showToast("Activation shortcut updated.")
    }

    func resetActivationHotkey() {
        setActivationHotkey(.defaultActivation)
    }

    func setPersonaHotkey(_ binding: HotkeyBinding) {
        guard binding.signature != activationHotkey.signature else {
            showToast("Persona shortcut cannot match the activation shortcut.")
            return
        }

        personaHotkey = binding
        settingsStore.personaHotkey = binding
        showToast("Persona shortcut updated.")
    }

    func resetPersonaHotkey() {
        setPersonaHotkey(.defaultPersona)
    }

    func applyPersonaSelection(_ id: UUID?) {
        settingsStore.applyPersonaSelection(id)
        syncPersonaSelectionFromStore()

        if let id, let persona = personas.first(where: { $0.id == id }) {
            showToast("Switched to \(persona.name).")
        } else {
            showToast("Persona disabled.")
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
            showToast("Persona saved.")
            return
        }

        guard let selectedPersonaID, let index = personas.firstIndex(where: { $0.id == selectedPersonaID }) else { return }
        personas[index].name = name
        personas[index].prompt = prompt
        persistPersonas()
        loadPersonaDraft()
        showToast("Persona saved.")
    }

    private func syncPersonaSelectionFromStore() {
        personaRewriteEnabled = settingsStore.personaRewriteEnabled
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
        ollamaStatus = "Preparing local model..."

        settingsStore.ollamaBaseURL = ollamaBaseURL
        settingsStore.ollamaModel = ollamaModel
        settingsStore.ollamaAutoSetup = ollamaAutoSetup

        Task {
            do {
                try await modelManager.ensureModelReady(settingsStore: settingsStore)
                ollamaStatus = "Local model is ready."
                showToast("Local model is ready.")
            } catch {
                ollamaStatus = "Failed: \(error.localizedDescription)"
                showToast("Local model preparation failed.")
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
            showToast("Local speech model is ready.")
            return
        }

        isPreparingLocalSTT = true
        localSTTStatus = "Preparing local speech model..."
        localSTTPreparationProgress = 0.02
        localSTTPreparationDetail = "Preparing local speech model..."
        isLocalSTTPrepared = false
        localSTTPreparedSource = "Automatic"
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
                localSTTStatus = "\(localSTTModel.displayName) is ready."
                localSTTPreparationProgress = 1
                localSTTPreparationDetail = "Download complete. Local speech model is ready."
                isLocalSTTPrepared = true
                refreshLocalSTTPreparedState()
                showToast("Local speech model is ready.")
            } catch {
                localSTTStatus = "Failed: \(error.localizedDescription)"
                localSTTPreparationDetail = "Preparation failed."
                isLocalSTTPrepared = false
                showToast("Local speech model preparation failed.")
            }
            isPreparingLocalSTT = false
        }
    }

    func exportHistory() {
        do {
            let url = try historyStore.exportMarkdown()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showToast("History exported.")
        } catch {
            showToast("Failed to export history.")
        }
    }

    func clearHistory() {
        historyStore.clear()
        historyRecords = []
        displayedHistory = []
        canLoadMoreHistory = false
        showToast("History cleared.")
    }

    func retryHistoryRecord(id: UUID) {
        guard let record = historyRecords.first(where: { $0.id == id }) else { return }
        onRetryHistory(record)
        showToast("Retry started.")
    }

    func copyTranscript(id: UUID) {
        guard
            let record = historyRecords.first(where: { $0.id == id }),
            let transcriptText = record.transcriptText,
            !transcriptText.isEmpty
        else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
        showToast("Transcript copied.")
    }

    func downloadAudio(id: UUID) {
        guard
            let record = historyRecords.first(where: { $0.id == id }),
            let audioFilePath = record.audioFilePath,
            !audioFilePath.isEmpty
        else { return }

        let sourceURL = URL(fileURLWithPath: audioFilePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            showToast("Audio file is unavailable.")
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
                showToast("Audio downloaded.")
            } catch {
                showToast("Failed to download audio.")
            }
        }
    }

    func deleteHistoryRecord(id: UUID) {
        historyStore.delete(id: id)
        historyRecords.removeAll { $0.id == id }
        displayedHistory.removeAll { $0.id == id }
        showToast("Transcript deleted.")
    }

    func applyModelConfiguration() {
        switch focusedModelProvider {
        case .openAICompatible:
            settingsStore.llmBaseURL = llmBaseURL
            settingsStore.llmModel = llmModel
            settingsStore.llmAPIKey = llmAPIKey
        case .ollama:
            settingsStore.ollamaBaseURL = ollamaBaseURL
            settingsStore.ollamaModel = ollamaModel
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
        showToast("Configuration saved.")
    }

    func testLLMConnection() {
        llmTestTask?.cancel()
        llmConnectionTestState = .testing

        let capturedProvider = focusedModelProvider
        let capturedBaseURL = llmBaseURL
        let capturedModel = llmModel.isEmpty ? "gpt-4o-mini" : llmModel
        let capturedAPIKey = llmAPIKey
        let capturedOllamaURL = ollamaBaseURL.isEmpty ? "http://127.0.0.1:11434" : ollamaBaseURL
        let capturedOllamaModel = ollamaModel

        llmTestTask = Task {
            let startDate = Date()
            var firstTokenDate: Date? = nil
            var collected = ""

            do {
                switch capturedProvider {
                case .openAICompatible:
                    guard !capturedBaseURL.isEmpty, let baseURL = URL(string: capturedBaseURL) else {
                        throw NSError(domain: "LLMTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL. Please enter a valid endpoint."])
                    }
                    let url = baseURL.appendingPathComponent("chat/completions")
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    if !capturedAPIKey.isEmpty {
                        urlRequest.setValue("Bearer \(capturedAPIKey)", forHTTPHeaderField: "Authorization")
                    }
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": capturedModel,
                        "stream": true,
                        "max_completion_tokens": 50,
                        "messages": [["role": "user", "content": "Hello"]]
                    ]
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    for try await chunk in try await SSEClient.lines(for: urlRequest) {
                        if Task.isCancelled { return }
                        if chunk == "[DONE]" { break }
                        guard let data = chunk.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty
                        else { continue }
                        if firstTokenDate == nil { firstTokenDate = Date() }
                        collected += content
                        if collected.count >= 60 { break }
                    }

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

                default:
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

    func copyLocalSTTStoragePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localSTTStoragePath, forType: .string)
        showToast("Storage path copied.")
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
            showToast("Permission status updated.")
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
                showToast(row.isGranted ? "\(row.title) is ready." : "Review \(row.title) in System Settings.")
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
            return llmProvider == .ollama ? .ollama : .openAICompatible
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
            errorMessage: record.errorMessage,
            applyMessage: record.applyMessage,
            hasTranscriptToCopy: !(record.transcriptText?.isEmpty ?? true),
            canRetry: record.hasFailure && record.audioFilePath.map { FileManager.default.fileExists(atPath: $0) } == true,
            hasFailure: record.hasFailure,
            failureMessage: record.errorMessage,
            accentName: iconData.0,
            accentColorName: iconData.1
        )
    }
}
