import AppKit
import Foundation
import SwiftUI

@MainActor
final class StudioViewModel: ObservableObject {
    @Published var currentSection: StudioSection
    @Published var searchQuery = ""
    @Published var modelDomain: StudioModelDomain = .stt
    @Published var focusedModelProvider: StudioModelProviderID

    @Published var sttProvider: STTProvider
    @Published var llmProvider: LLMProvider
    @Published var appearanceMode: AppearanceMode

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

    @Published var activationHotkey: HotkeyBinding
    @Published var personaHotkey: HotkeyBinding
    @Published private(set) var historyRecords: [HistoryRecord]
    @Published var toastMessage: String?
    @Published private(set) var permissionRows: [StudioPermissionRowModel] = []
    @Published private(set) var isRefreshingPermissions = false
    @Published private(set) var isRefreshingHistory = false

    let errorLogStore = ErrorLogStore.shared

    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let modelManager: OllamaLocalModelManager
    private let localSTTServiceManager: LocalSTTServiceManager
    private let onRetryHistory: (HistoryRecord) -> Void
    private var historyObserver: NSObjectProtocol?

    init(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        initialSection: StudioSection,
        onRetryHistory: @escaping (HistoryRecord) -> Void = { _ in },
        modelManager: OllamaLocalModelManager = OllamaLocalModelManager(),
        localSTTServiceManager: LocalSTTServiceManager = LocalSTTServiceManager()
    ) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.modelManager = modelManager
        self.localSTTServiceManager = localSTTServiceManager
        self.onRetryHistory = onRetryHistory

        let currentPersonas = settingsStore.personas

        currentSection = initialSection
        sttProvider = settingsStore.sttProvider
        llmProvider = settingsStore.llmProvider
        switch settingsStore.sttProvider {
        case .appleSpeech:
            focusedModelProvider = .appleSpeech
        case .localModel:
            focusedModelProvider = .localSTT
        case .whisperAPI:
            focusedModelProvider = .whisperAPI
        case .multimodalLLM:
            focusedModelProvider = .multimodalLLM
        }
        appearanceMode = settingsStore.appearanceMode
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
        activationHotkey = settingsStore.activationHotkey
        personaHotkey = settingsStore.personaHotkey
        historyRecords = historyStore.list()
        settingsStore.localSTTModelIdentifier = localSTTModelIdentifier
        settingsStore.localSTTDownloadSource = localSTTModel.recommendedDownloadSource
        settingsStore.localSTTAutoSetup = true
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
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
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

    var displayedHistory: [HistoryPresentationRecord] {
        filteredHistory.map(makeHistoryPresentation)
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

    var transcriptionMinutesText: String {
        let minutes = historyRecords.count * 3 + historyRecords.reduce(0) { $0 + min($1.text.count / 80, 12) }
        return NumberFormatter.localizedString(from: NSNumber(value: minutes), number: .decimal)
    }

    var completedTranscriptionsText: String {
        NumberFormatter.localizedString(from: NSNumber(value: historyRecords.count), number: .decimal)
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
            case .whisperAPI, .multimodalLLM:
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
            }
        case .llm:
            return llmProvider == .ollama ? "Using local Ollama generation." : "Using remote chat-completion endpoints."
        }
    }

    func navigate(to section: StudioSection) {
        currentSection = section
        searchQuery = ""
        refreshHistory()
    }

    func refreshHistory() {
        historyRecords = historyStore.list()
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
    }

    func setLLMBaseURL(_ value: String) { llmBaseURL = value; settingsStore.llmBaseURL = value }
    func setLLMModel(_ value: String) { llmModel = value; settingsStore.llmModel = value }
    func setLLMAPIKey(_ value: String) { llmAPIKey = value; settingsStore.llmAPIKey = value }
    func setOllamaBaseURL(_ value: String) { ollamaBaseURL = value; settingsStore.ollamaBaseURL = value }
    func setOllamaModel(_ value: String) { ollamaModel = value; settingsStore.ollamaModel = value }
    func setOllamaAutoSetup(_ value: Bool) { ollamaAutoSetup = value; settingsStore.ollamaAutoSetup = value }
    func setWhisperBaseURL(_ value: String) { whisperBaseURL = value; settingsStore.whisperBaseURL = value }
    func setWhisperModel(_ value: String) { whisperModel = value; settingsStore.whisperModel = value }
    func setWhisperAPIKey(_ value: String) { whisperAPIKey = value; settingsStore.whisperAPIKey = value }
    func setMultimodalLLMBaseURL(_ value: String) { multimodalLLMBaseURL = value; settingsStore.multimodalLLMBaseURL = value }
    func setMultimodalLLMModel(_ value: String) { multimodalLLMModel = value; settingsStore.multimodalLLMModel = value }
    func setMultimodalLLMAPIKey(_ value: String) { multimodalLLMAPIKey = value; settingsStore.multimodalLLMAPIKey = value }
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
    func setPersonaRewriteEnabled(_ value: Bool) { personaRewriteEnabled = value; settingsStore.personaRewriteEnabled = value }

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
        setDefaultPersonaSelection(id)

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
        settingsStore.activePersonaID = selectedPersona.id.uuidString
        activePersonaID = selectedPersona.id.uuidString
        if !personaRewriteEnabled {
            setPersonaRewriteEnabled(true)
        }
    }

    func deactivatePersonaRewrite() {
        setPersonaRewriteEnabled(false)
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
        refreshHistory()
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
        refreshHistory()
        showToast("Transcript deleted.")
    }

    func applyModelConfiguration() {
        showToast("Configuration saved.")
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

    private var filteredHistory: [HistoryRecord] {
        guard !searchQuery.isEmpty else { return historyRecords }
        return historyRecords.filter {
            $0.text.localizedCaseInsensitiveContains(searchQuery) ||
            ($0.transcriptText?.localizedCaseInsensitiveContains(searchQuery) ?? false) ||
            ($0.personaResultText?.localizedCaseInsensitiveContains(searchQuery) ?? false) ||
            ($0.selectionEditedText?.localizedCaseInsensitiveContains(searchQuery) ?? false) ||
            ($0.errorMessage?.localizedCaseInsensitiveContains(searchQuery) ?? false) ||
            ($0.audioFilePath.map { URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveContains(searchQuery) } ?? false)
        }
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
            }
        case .llm:
            return llmProvider == .ollama ? .ollama : .openAICompatible
        }
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
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

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
