import AppKit
import Foundation
import SwiftUI

// swiftlint:disable type_body_length file_length
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case language = 0
        case account = 1
        case stt = 2
        case llm = 3
        case permissions = 4
        case shortcuts = 5

        var analyticsName: String {
            switch self {
            case .language: "language"
            case .account: "account"
            case .stt: "stt"
            case .llm: "llm"
            case .permissions: "permissions"
            case .shortcuts: "shortcuts"
            }
        }
    }

    enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success(totalMs: Int, preview: String)
        case failure(message: String)
    }

    enum ExternalKeyboardShortcutReplacement: String, CaseIterable, Equatable {
        case rightCommand
        case rightOption

        var activationHotkey: HotkeyBinding {
            switch self {
            case .rightCommand:
                .rightCommandActivation
            case .rightOption:
                .rightOptionActivation
            }
        }

        var askHotkey: HotkeyBinding {
            switch self {
            case .rightCommand:
                .rightCommandAsk
            case .rightOption:
                .rightOptionAsk
            }
        }
    }

    static let orderedSteps: [Step] = [.language, .account, .stt, .llm, .permissions, .shortcuts]

    @Published var currentStep: Step = .language
    @Published var stepDirection: Int = 1 // 1 = forward, -1 = backward
    @Published private(set) var useCloudAccountModels: Bool

    /// Language
    @Published var appLanguage: AppLanguage

    // Connection testing
    @Published var sttConnectionTestState: ConnectionTestState = .idle
    @Published var llmConnectionTestState: ConnectionTestState = .idle
    private var sttTestTask: Task<Void, Never>?
    private var llmTestTask: Task<Void, Never>?

    // STT Config
    @Published var sttProvider: STTProvider
    @Published var whisperBaseURL: String
    @Published var whisperAPIKey: String
    @Published var whisperModel: String
    @Published var freeSTTModel: String
    @Published var localSTTModel: LocalSTTModel
    @Published var multimodalLLMBaseURL: String
    @Published var multimodalLLMAPIKey: String
    @Published var multimodalLLMModel: String
    @Published var aliCloudAPIKey: String
    @Published var doubaoAppID: String
    @Published var doubaoAccessToken: String
    @Published var doubaoResourceID: String
    @Published var googleCloudProjectID: String
    @Published var googleCloudAPIKey: String
    @Published var googleCloudModel: String
    @Published var groqSTTAPIKey: String
    @Published var groqSTTModel: String
    @Published var sonioxAPIKey: String
    @Published var sonioxModel: String

    // LLM Config
    @Published var llmProvider: LLMProvider
    @Published var llmRemoteProvider: LLMRemoteProvider
    @Published var llmBaseURL: String
    @Published var llmModel: String
    @Published var llmAPIKey: String
    @Published var ollamaBaseURL: String
    @Published var ollamaModel: String

    // Permissions
    @Published var permissions: [PrivacyGuard.PermissionSnapshot] = []
    @Published var requestingPermissions: Set<PrivacyGuard.PermissionID> = []
    @Published var showIncompletePermissionsAlert = false
    @Published var showIncompleteSTTConfigurationAlert = false
    @Published var showIncompleteLLMConfigurationAlert = false

    // Globe key (🌐) macOS keyboard setting
    @Published var isGlobeKeyReady: Bool = true
    @Published private(set) var activationHotkey: HotkeyBinding
    @Published private(set) var askHotkey: HotkeyBinding?
    @Published private(set) var historyHotkey: HotkeyBinding
    @Published private(set) var externalKeyboardShortcutReplacement: ExternalKeyboardShortcutReplacement?
    @Published var showShortcutReplacementAppliedAlert = false

    private let settingsStore: SettingsStore
    private let authState: AuthState
    private let globeKeyReader: GlobeKeyPreferenceReading
    private let localModelManager: (any LocalSTTModelManaging)?
    private let notificationService: LocalNotificationSending
    private let analyticsReporter: AnalyticsEventReporting
    private let permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor?
    private let onboardingStartedAt: Date
    private let now: () -> Date
    private var didReportTerminalEvent = false
    let onComplete: () -> Void
    private var cloudAccountModelDefaultsObserver: NSObjectProtocol?
    private var localSTTPreparationTask: Task<Void, Never>?
    private var localSTTPreparationModel: LocalSTTModel?

    init(
        settingsStore: SettingsStore,
        authState: AuthState? = nil,
        globeKeyReader: GlobeKeyPreferenceReading = SystemGlobeKeyPreferenceReader(),
        localModelManager: (any LocalSTTModelManaging)? = nil,
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
        analyticsReporter: AnalyticsEventReporting = NoopAnalyticsEventReporter.shared,
        permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor? = nil,
        now: @escaping () -> Date = { Date() },
        onComplete: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        let resolvedAuthState = authState ?? .shared
        self.authState = resolvedAuthState
        self.globeKeyReader = globeKeyReader
        self.localModelManager = localModelManager
        self.notificationService = notificationService
        self.analyticsReporter = analyticsReporter
        self.permissionStatusAnalyticsMonitor = permissionStatusAnalyticsMonitor
        self.now = now
        onboardingStartedAt = now()
        self.onComplete = onComplete
        let initialUseCloudAccountModels = resolvedAuthState.isLoggedIn
            && settingsStore.sttProvider == .typefluxOfficial
            && settingsStore.llmProvider == .openAICompatible
            && settingsStore.llmRemoteProvider == .typefluxCloud
        useCloudAccountModels = initialUseCloudAccountModels

        appLanguage = settingsStore.appLanguage
        sttProvider = {
            let p = settingsStore.sttProvider
            // Never show providers that are hidden from onboarding model selection.
            return switch p {
            case .appleSpeech, .typefluxOfficial:
                STTProvider.defaultProvider
            default:
                p
            }
        }()
        whisperBaseURL = settingsStore.whisperBaseURL
        whisperAPIKey = settingsStore.whisperAPIKey
        whisperModel = settingsStore.whisperModel
        freeSTTModel = settingsStore.freeSTTModel
        localSTTModel = settingsStore.localSTTModel
        multimodalLLMBaseURL = settingsStore.multimodalLLMBaseURL
        multimodalLLMAPIKey = settingsStore.multimodalLLMAPIKey
        multimodalLLMModel = settingsStore.multimodalLLMModel
        aliCloudAPIKey = settingsStore.aliCloudAPIKey
        doubaoAppID = settingsStore.doubaoAppID
        doubaoAccessToken = settingsStore.doubaoAccessToken
        doubaoResourceID = settingsStore.doubaoResourceID
        googleCloudProjectID = settingsStore.googleCloudProjectID
        googleCloudAPIKey = settingsStore.googleCloudAPIKey
        googleCloudModel = settingsStore.googleCloudModel
        groqSTTAPIKey = settingsStore.groqSTTAPIKey
        groqSTTModel = settingsStore.groqSTTModel
        sonioxAPIKey = settingsStore.sonioxAPIKey
        sonioxModel = settingsStore.sonioxModel

        let initialLLMProvider = settingsStore.llmProvider
        let storedRemoteProvider = settingsStore.llmRemoteProvider
        let shouldHideStoredCloudProvider = !initialUseCloudAccountModels
            && initialLLMProvider == .openAICompatible
            && storedRemoteProvider == .typefluxCloud
        let initialRemoteProvider: LLMRemoteProvider = shouldHideStoredCloudProvider ? .custom : storedRemoteProvider
        llmProvider = initialLLMProvider
        llmRemoteProvider = initialRemoteProvider
        llmBaseURL = settingsStore.llmBaseURL(for: initialRemoteProvider)
        llmModel = settingsStore.llmModel(for: initialRemoteProvider)
        llmAPIKey = settingsStore.llmAPIKey(for: initialRemoteProvider)
        ollamaBaseURL = settingsStore.ollamaBaseURL
        ollamaModel = settingsStore.ollamaModel

        permissions = PrivacyGuard.snapshots()
        isGlobeKeyReady = globeKeyReader.isReadyForHotkey
        let storedActivationHotkey = settingsStore.activationHotkey ?? .defaultActivation
        let storedAskHotkey = settingsStore.askHotkey
        let storedHistoryHotkey = settingsStore.historyHotkey ?? .defaultHistory
        activationHotkey = storedActivationHotkey
        askHotkey = storedAskHotkey
        historyHotkey = storedHistoryHotkey
        externalKeyboardShortcutReplacement = Self.detectExternalKeyboardShortcutReplacement(
            activationHotkey: storedActivationHotkey,
            askHotkey: storedAskHotkey
        )

        cloudAccountModelDefaultsObserver = NotificationCenter.default.addObserver(
            forName: .cloudAccountModelDefaultsDidApply,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncCloudAccountModelsFromStore()
            }
        }
    }

    deinit {
        if let cloudAccountModelDefaultsObserver {
            NotificationCenter.default.removeObserver(cloudAccountModelDefaultsObserver)
        }
        localSTTPreparationTask?.cancel()
    }

    var canGoBack: Bool {
        currentStep != visibleSteps.first
    }

    var isLastStep: Bool {
        currentStep == visibleSteps.last
    }

    var visibleSteps: [Step] {
        if useCloudAccountModels {
            return Self.orderedSteps.filter { $0 != .stt && $0 != .llm }
        }
        if sttProvider == .multimodalLLM {
            return Self.orderedSteps.filter { $0 != .llm }
        }
        return Self.orderedSteps
    }

    var isSkippable: Bool {
        switch currentStep {
        case .language, .permissions:
            true
        case .account, .stt, .llm, .shortcuts:
            false
        }
    }

    var isSTTConfigurationComplete: Bool {
        switch sttProvider {
        case .localModel, .appleSpeech, .typefluxOfficial:
            true
        case .freeModel:
            hasText(freeSTTModel)
        case .whisperAPI:
            hasText(whisperBaseURL) && hasText(whisperAPIKey) && hasText(whisperModel)
        case .multimodalLLM:
            hasText(multimodalLLMBaseURL) && hasText(multimodalLLMAPIKey) && hasText(multimodalLLMModel)
        case .aliCloud:
            hasText(aliCloudAPIKey)
        case .doubaoRealtime:
            hasText(doubaoAppID) && hasText(doubaoAccessToken) && hasText(doubaoResourceID)
        case .googleCloud:
            hasText(googleCloudProjectID) && hasText(googleCloudModel)
        case .groq:
            hasText(groqSTTAPIKey) && hasText(groqSTTModel)
        case .soniox:
            hasText(sonioxAPIKey)
        }
    }

    var isLLMConfigurationComplete: Bool {
        switch llmProvider {
        case .ollama:
            hasText(ollamaBaseURL) && hasText(ollamaModel)
        case .openAICompatible:
            switch llmRemoteProvider {
            case .typefluxCloud:
                authState.isLoggedIn
            case .freeModel:
                hasText(llmModel)
            case .custom:
                hasText(llmBaseURL) && hasText(llmModel)
            default:
                hasText(llmBaseURL) && hasText(llmModel) && hasText(llmAPIKey)
            }
        }
    }

    var allRequiredPermissionsGranted: Bool {
        let required = PrivacyGuard.requiredPermissionIDs(settingsStore: settingsStore)
        return required.allSatisfy { id in
            permissions.first(where: { $0.id == id })?.isGranted ?? false
        }
    }

    func goBack() {
        guard canGoBack else { return }
        let previousStep = adjacentStep(offset: -1) ?? (visibleSteps.first ?? .language)
        stepDirection = -1
        withAnimation(.easeInOut(duration: 0.22)) {
            currentStep = previousStep
        }
    }

    func advance() {
        if currentStep == .stt, !isSTTConfigurationComplete {
            showIncompleteSTTConfigurationAlert = true
            return
        }
        if currentStep == .stt {
            showIncompleteSTTConfigurationAlert = false
        }

        if currentStep == .llm, !isLLMConfigurationComplete {
            showIncompleteLLMConfigurationAlert = true
            return
        }
        if currentStep == .llm {
            showIncompleteLLMConfigurationAlert = false
        }

        if currentStep == .permissions, !allRequiredPermissionsGranted {
            showIncompletePermissionsAlert = true
            return
        }

        saveCurrentStepSettings()
        reportCurrentStepCompleted(skipped: false)
        advanceToNextStepOrComplete()
    }

    func skip() {
        reportCurrentStepCompleted(skipped: true)
        if isLastStep {
            complete()
        } else {
            let nextStep = adjacentStep(offset: 1) ?? (visibleSteps.last ?? .shortcuts)
            stepDirection = 1
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStep = nextStep
            }
        }
    }

    /// Marks onboarding as complete without triggering the completion callback.
    /// Used when the window is closed externally (e.g., user clicks the close button).
    func skipWithoutAnimation() {
        reportAbandonedIfNeeded()
        settingsStore.applyDefaultPersonaIfLLMConfigured()
        settingsStore.isOnboardingCompleted = true
    }

    func useCloudAccountModelsAndContinue() {
        guard authState.isLoggedIn else { return }
        syncCloudAccountModelsFromStore()
        advance()
    }

    func continueWithoutCloudAccount() {
        useCloudAccountModels = false
        advance()
    }

    func skipIncompleteLLMConfiguration() {
        guard currentStep == .llm else { return }
        showIncompleteLLMConfigurationAlert = false
        saveCurrentStepSettings()
        reportCurrentStepCompleted(skipped: true)
        advanceToNextStepOrComplete()
    }

    func selectOllama() {
        llmProvider = .ollama
        llmConnectionTestState = .idle
    }

    func selectSTTProvider(_ provider: STTProvider) {
        sttProvider = provider
        sttConnectionTestState = .idle
        if provider == .localModel {
            prepareSelectedLocalSTTModelInBackground()
        }
    }

    func selectLocalSTTModel(_ model: LocalSTTModel) {
        localSTTModel = model
        guard sttProvider == .localModel else { return }
        prepareSelectedLocalSTTModelInBackground()
    }

    func selectLLMRemoteProvider(_ provider: LLMRemoteProvider) {
        llmProvider = .openAICompatible
        llmRemoteProvider = provider
        llmBaseURL = settingsStore.llmBaseURL(for: provider)
        llmAPIKey = settingsStore.llmAPIKey(for: provider)
        llmModel = settingsStore.llmModel(for: provider)
        llmConnectionTestState = .idle
    }

    func testSTTConnection() {
        sttTestTask?.cancel()
        sttConnectionTestState = .testing

        let provider = sttProvider
        let baseURL = whisperBaseURL
        let model = whisperModel
        let apiKey = whisperAPIKey
        let multimodalBaseURL = multimodalLLMBaseURL
        let multimodalModel = multimodalLLMModel
        let multimodalAPIKey = multimodalLLMAPIKey
        let aliKey = aliCloudAPIKey
        let doubaoID = doubaoAppID
        let doubaoToken = doubaoAccessToken
        let doubaoResource = doubaoResourceID
        let googleProjectID = googleCloudProjectID
        let googleAPIKey = ""
        let googleModel = googleCloudModel
        let language = appLanguage
        let groqKey = groqSTTAPIKey
        let groqModel = groqSTTModel
        let sonioxKey = sonioxAPIKey
        let sonioxModelValue = sonioxModel
        let freeModel = freeSTTModel

        sttTestTask = Task {
            let start = Date()
            do {
                let preview = try await ConnectionTestSupport.runWithTimeout {
                    let preview: String
                    switch provider {
                    case .whisperAPI:
                        preview = try await WhisperAPITranscriber.testConnection(
                            baseURL: baseURL,
                            model: model,
                            apiKey: apiKey
                        )
                    case .multimodalLLM:
                        preview = try await MultimodalLLMTranscriber.testConnection(
                            baseURL: multimodalBaseURL,
                            model: multimodalModel,
                            apiKey: multimodalAPIKey
                        )
                    case .aliCloud:
                        preview = try await AliCloudRealtimeTranscriber.testConnection(apiKey: aliKey)
                    case .doubaoRealtime:
                        preview = try await DoubaoRealtimeTranscriber.testConnection(
                            appID: doubaoID,
                            accessToken: doubaoToken,
                            resourceID: doubaoResource
                        )
                    case .googleCloud:
                        preview = try await GoogleCloudSpeechTranscriber.testConnection(
                            projectID: googleProjectID,
                            apiKey: googleAPIKey,
                            model: googleModel,
                            appLanguage: language
                        )
                    case .groq:
                        let effectiveModel = groqModel.isEmpty
                            ? OpenAIAudioModelCatalog.groqWhisperModels[0] : groqModel
                        preview = try await WhisperAPITranscriber.testConnection(
                            baseURL: "https://api.groq.com/openai/v1",
                            model: effectiveModel,
                            apiKey: groqKey
                        )
                    case .soniox:
                        preview = try await SonioxTranscriber.testConnection(
                            apiKey: sonioxKey,
                            model: sonioxModelValue
                        )
                    case .freeModel:
                        preview = try await FreeSTTTranscriber.testConnection(modelName: freeModel)
                    case .localModel, .appleSpeech, .typefluxOfficial:
                        preview = ""
                    }
                    return preview
                }
                guard !Task.isCancelled else { return }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                sttConnectionTestState = .success(totalMs: ms, preview: String(preview.prefix(120)))
            } catch {
                guard !Task.isCancelled else { return }
                sttConnectionTestState = .failure(message: error.localizedDescription)
            }
        }
    }

    func testLLMConnection() {
        llmTestTask?.cancel()
        llmConnectionTestState = .testing

        let provider = llmProvider
        let remoteProvider = llmRemoteProvider
        let baseURL = llmBaseURL
        let model = llmModel
        let apiKey = llmAPIKey
        let ollamaURL = ollamaBaseURL.isEmpty ? "http://127.0.0.1:11434" : ollamaBaseURL
        let ollamaModel = ollamaModel

        llmTestTask = Task {
            let start = Date()
            do {
                let preview = try await ConnectionTestSupport.runWithTimeout {
                    if provider == .ollama {
                        guard let base = URL(string: ollamaURL) else {
                            throw NSError(
                                domain: "LLMTest",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL."]
                            )
                        }
                        let url = base.appendingPathComponent("api/chat")
                        var req = URLRequest(
                            url: url,
                            timeoutInterval: TimeInterval(ConnectionTestSupport.timeoutSeconds)
                        )
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = try JSONSerialization.data(withJSONObject: [
                            "model": ollamaModel,
                            "stream": false,
                            "messages": [["role": "user", "content": "Reply with exactly: ok"]],
                            "options": ["num_predict": 10]
                        ])
                        let (data, response) = try await URLSession.shared.data(for: req)
                        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                            throw NSError(domain: "LLMTest", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: msg])
                        }
                        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let message = json?["message"] as? [String: Any]
                        return (message?["content"] as? String) ?? ""
                    } else {
                        let connection = try await LLMConnectionTestResolver.resolve(
                            provider: remoteProvider,
                            baseURL: baseURL,
                            model: model,
                            apiKey: apiKey
                        )
                        return try await RemoteLLMClient.previewConnection(
                            provider: connection.provider,
                            baseURL: connection.baseURL,
                            model: connection.model,
                            apiKey: connection.apiKey,
                            additionalHeaders: connection.headers(for: .modelSetup)
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                llmConnectionTestState = .success(
                    totalMs: ms,
                    preview: String(preview.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                )
            } catch {
                guard !Task.isCancelled else { return }
                llmConnectionTestState = .failure(message: error.localizedDescription)
            }
        }
    }

    func setLanguage(_ language: AppLanguage) {
        appLanguage = language
        settingsStore.appLanguage = language
        AppLocalization.shared.setLanguage(language)
    }

    func refreshPermissions() {
        permissions = PrivacyGuard.snapshots()
    }

    func refreshGlobeKeyState() {
        isGlobeKeyReady = globeKeyReader.isReadyForHotkey
    }

    func useExternalKeyboardShortcutReplacement(_ replacement: ExternalKeyboardShortcutReplacement) {
        activationHotkey = replacement.activationHotkey
        askHotkey = replacement.askHotkey
        externalKeyboardShortcutReplacement = replacement
        settingsStore.activationHotkey = replacement.activationHotkey
        settingsStore.askHotkey = replacement.askHotkey
        showShortcutReplacementAppliedAlert = true
    }

    func restoreDefaultFNShortcuts() {
        activationHotkey = .defaultActivation
        askHotkey = .defaultAsk
        externalKeyboardShortcutReplacement = nil
        settingsStore.activationHotkey = .defaultActivation
        settingsStore.askHotkey = .defaultAsk
        showShortcutReplacementAppliedAlert = true
    }

    static let keyboardSystemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )!

    func openKeyboardSystemSettings() {
        NSWorkspace.shared.open(Self.keyboardSystemSettingsURL)
    }

    func requestPermission(_ id: PrivacyGuard.PermissionID) {
        guard !requestingPermissions.contains(id) else { return }
        requestingPermissions.insert(id)
        // Capture whether this will show an in-app system dialog (not open System Preferences).
        // After such dialogs are dismissed, the app loses focus and needs to be re-activated.
        let willShowInAppDialog = PrivacyGuard.willShowInAppDialog(for: id)
        Task {
            await PrivacyGuard.requestPermission(id)
            refreshPermissions()
            permissionStatusAnalyticsMonitor?.observe(permissions)
            requestingPermissions.remove(id)
            if willShowInAppDialog {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func saveCurrentStepSettings() {
        switch currentStep {
        case .language:
            settingsStore.appLanguage = appLanguage
            AppLocalization.shared.setLanguage(appLanguage)
        case .account:
            guard useCloudAccountModels else { return }
            sttProvider = .typefluxOfficial
            llmProvider = .openAICompatible
            llmRemoteProvider = .typefluxCloud
            llmBaseURL = settingsStore.llmBaseURL(for: .typefluxCloud)
            llmModel = settingsStore.llmModel(for: .typefluxCloud)
            llmAPIKey = settingsStore.llmAPIKey(for: .typefluxCloud)
            settingsStore.sttProvider = .typefluxOfficial
            settingsStore.llmProvider = .openAICompatible
            settingsStore.llmRemoteProvider = .typefluxCloud
        case .stt:
            settingsStore.sttProvider = sttProvider
            switch sttProvider {
            case .freeModel:
                settingsStore.freeSTTModel = freeSTTModel
            case .whisperAPI:
                settingsStore.whisperBaseURL = whisperBaseURL
                settingsStore.whisperAPIKey = whisperAPIKey
                settingsStore.whisperModel = whisperModel
            case .localModel:
                settingsStore.localSTTModel = localSTTModel
                applySelectedLocalSTTDefaults()
            case .multimodalLLM:
                settingsStore.multimodalLLMBaseURL = multimodalLLMBaseURL
                settingsStore.multimodalLLMAPIKey = multimodalLLMAPIKey
                settingsStore.multimodalLLMModel = multimodalLLMModel
            case .aliCloud:
                settingsStore.aliCloudAPIKey = aliCloudAPIKey
            case .doubaoRealtime:
                settingsStore.doubaoAppID = doubaoAppID
                settingsStore.doubaoAccessToken = doubaoAccessToken
                settingsStore.doubaoResourceID = doubaoResourceID
            case .googleCloud:
                settingsStore.googleCloudProjectID = googleCloudProjectID
                settingsStore.googleCloudAPIKey = ""
                settingsStore.googleCloudModel = googleCloudModel
            case .groq:
                settingsStore.groqSTTAPIKey = groqSTTAPIKey
                settingsStore.groqSTTModel = groqSTTModel
            case .soniox:
                settingsStore.sonioxAPIKey = sonioxAPIKey
                settingsStore.sonioxModel = sonioxModel
            case .appleSpeech, .typefluxOfficial:
                break
            }
        case .llm:
            settingsStore.llmProvider = llmProvider
            if llmProvider == .openAICompatible {
                settingsStore.llmRemoteProvider = llmRemoteProvider
                settingsStore.setLLMBaseURL(llmBaseURL, for: llmRemoteProvider)
                settingsStore.setLLMAPIKey(llmAPIKey, for: llmRemoteProvider)
                settingsStore.setLLMModel(llmModel, for: llmRemoteProvider)
            } else {
                settingsStore.ollamaBaseURL = ollamaBaseURL
                settingsStore.ollamaModel = ollamaModel
            }
        case .permissions, .shortcuts:
            break
        }
    }

    private func syncCloudAccountModelsFromStore() {
        useCloudAccountModels = true
        sttProvider = .typefluxOfficial
        llmProvider = .openAICompatible
        llmRemoteProvider = .typefluxCloud
        llmBaseURL = settingsStore.llmBaseURL(for: .typefluxCloud)
        llmModel = settingsStore.llmModel(for: .typefluxCloud)
        llmAPIKey = settingsStore.llmAPIKey(for: .typefluxCloud)
        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud
        sttConnectionTestState = .idle
        llmConnectionTestState = .idle
    }

    private func complete() {
        guard !didReportTerminalEvent else { return }
        didReportTerminalEvent = true
        let duration = max(0, Int(now().timeIntervalSince(onboardingStartedAt)))
        analyticsReporter.report(
            eventName: "onboarding_completed",
            properties: [
                "duration_seconds": "\(duration)",
                "stt_provider": sttProvider.rawValue,
                "llm_provider": llmProvider.rawValue
            ]
        )
        settingsStore.applyDefaultPersonaIfLLMConfigured()
        settingsStore.isOnboardingCompleted = true
        onComplete()
    }

    private func reportCurrentStepCompleted(skipped: Bool) {
        analyticsReporter.report(
            eventName: "onboarding_step_completed",
            properties: [
                "step": currentStep.analyticsName,
                "skipped": "\(skipped)"
            ]
        )
    }

    private func reportAbandonedIfNeeded() {
        guard !didReportTerminalEvent else { return }
        didReportTerminalEvent = true
        analyticsReporter.report(
            eventName: "onboarding_abandoned",
            properties: ["last_step": currentStep.analyticsName]
        )
    }

    private func advanceToNextStepOrComplete() {
        if isLastStep {
            complete()
        } else {
            let nextStep = adjacentStep(offset: 1) ?? (visibleSteps.last ?? .shortcuts)
            stepDirection = 1
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStep = nextStep
            }
        }
    }

    private func prepareSelectedLocalSTTModelInBackground() {
        guard let localModelManager else { return }

        applySelectedLocalSTTDefaults()
        let targetModel = localSTTModel
        let configuration = localSTTConfiguration(for: targetModel)

        if localModelManager.isModelAvailable(targetModel) {
            LocalModelDownloadProgressCenter.shared.clear()
            return
        }

        if localSTTPreparationModel == targetModel, localSTTPreparationTask != nil {
            return
        }

        localSTTPreparationTask?.cancel()
        localSTTPreparationModel = targetModel
        LocalModelDownloadProgressCenter.shared.reportDownloading(model: targetModel, progress: 0.02)
        localSTTPreparationTask = Task { [weak self, localModelManager, notificationService] in
            do {
                try await localModelManager.prepareModel(configuration: configuration) { update in
                    LocalModelDownloadProgressCenter.shared.reportDownloading(
                        model: targetModel,
                        progress: update.progress
                    )
                }
                guard !Task.isCancelled else { return }
                LocalModelDownloadProgressCenter.shared.clear()
                await notificationService.sendLocalNotification(
                    title: L("notification.localModelReady.title"),
                    body: L("notification.localModelReady.body"),
                    identifier: "ai.gulu.app.typeflux.local-model-ready"
                )
            } catch {
                guard !Task.isCancelled else {
                    LocalModelDownloadProgressCenter.shared.clear()
                    return
                }
                NetworkDebugLogger.logError(context: "Onboarding local STT model download failed", error: error)
                LocalModelDownloadProgressCenter.shared.reportFailed(
                    model: targetModel,
                    message: error.localizedDescription
                )
            }
            await MainActor.run {
                guard self?.localSTTPreparationModel == targetModel else { return }
                self?.localSTTPreparationModel = nil
                self?.localSTTPreparationTask = nil
            }
        }
    }

    private func applySelectedLocalSTTDefaults() {
        settingsStore.localSTTModel = localSTTModel
        settingsStore.localSTTModelIdentifier = localSTTModel.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = localSTTModel.recommendedDownloadSource
        settingsStore.localSTTAutoSetup = true
    }

    private func localSTTConfiguration(for model: LocalSTTModel) -> LocalSTTConfiguration {
        LocalSTTConfiguration(
            model: model,
            modelIdentifier: model.defaultModelIdentifier,
            downloadSource: model.recommendedDownloadSource,
            autoSetup: true
        )
    }

    private func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func adjacentStep(offset: Int) -> Step? {
        let steps = visibleSteps
        guard let index = steps.firstIndex(of: currentStep) else {
            if offset > 0 {
                return steps.first(where: { $0.rawValue > currentStep.rawValue }) ?? steps.last
            }
            return steps.last(where: { $0.rawValue < currentStep.rawValue }) ?? steps.first
        }

        let nextIndex = index + offset
        guard steps.indices.contains(nextIndex) else { return nil }
        return steps[nextIndex]
    }

    private static func detectExternalKeyboardShortcutReplacement(
        activationHotkey: HotkeyBinding,
        askHotkey: HotkeyBinding?
    ) -> ExternalKeyboardShortcutReplacement? {
        ExternalKeyboardShortcutReplacement.allCases.first { replacement in
            activationHotkey.signature == replacement.activationHotkey.signature
                && askHotkey?.signature == replacement.askHotkey.signature
        }
    }
}
