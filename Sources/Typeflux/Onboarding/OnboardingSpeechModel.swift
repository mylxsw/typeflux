import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class OnboardingSpeechModel: ObservableObject {
    weak var session: OnboardingViewModel?

    enum TestStatus: Equatable {
        case idle
        case recording
        case recognizing
        case success(preview: String, latencyMs: Int)
        case failure(message: String)
    }

    @Published private(set) var selectedProvider: STTProvider = .localModel
    @Published private(set) var selectedLocalModel: LocalSTTModel = .senseVoiceSmall
    @Published var isDownloading = false
    @Published var downloadProgress = 0.0
    @Published var apiKey = "" {
        didSet { credentialsChanged() }
    }

    @Published var doubaoAppID = "" {
        didSet { credentialsChanged() }
    }

    @Published var doubaoAccessToken = "" {
        didSet { credentialsChanged() }
    }

    @Published var whisperBaseURL = "https://api.openai.com/v1" {
        didSet { credentialsChanged() }
    }

    @Published var googleProjectID = "" {
        didSet { credentialsChanged() }
    }

    @Published var isGoogleAuthorized = false
    @Published private(set) var isAuthorizingGoogle = false
    @Published var isMicrophoneDenied = false
    @Published var testStatus: TestStatus = .idle
    @Published var canContinue: Bool? = false
    @Published var isBusy = false
    @Published var primaryAction: (() -> Void)?

    var audioAuthorizationProvider: () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var requestMicrophoneAccess: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var makeRecorder: () -> any AudioRecorder
    var makeTranscriber: (STTProvider) -> any Transcriber
    var authorizeGoogle: () async throws -> Void = {
        let token = try await GoogleOAuthService.authorizeGoogleCloud(
            clientID: AppServerConfiguration.googleCloudOAuthClientID,
            clientSecret: AppServerConfiguration.googleCloudOAuthClientSecret.isEmpty
                ? nil : AppServerConfiguration.googleCloudOAuthClientSecret
        )
        try Task.checkCancellation()
        GoogleCloudSpeechOAuthTokenStore.save(token)
    }

    private var testTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var recorder: (any AudioRecorder)?
    private var isHolding = false
    private var isSyncing = false
    private var recordingSignature: [String]?
    private var generation = UUID()
    private var downloadGeneration = UUID()

    init(session: OnboardingViewModel) {
        self.session = session
        let store = session.settingsStore
        let manager = session.localModelManager ?? LocalModelManager()
        makeRecorder = { SwitchableAudioRecorder(settingsStore: store, audioDeviceManager: AudioDeviceManager()) }
        makeTranscriber = { OnboardingSpeechTranscriber.make($0, settings: store, manager: manager) }
        selectedProvider = store.sttProvider == .typefluxOfficial ? .localModel : store.sttProvider
        selectedLocalModel = store.localSTTModel
        syncCredentialsForSelectedProvider()
        refreshMicrophoneStatus()
        NotificationCenter.default.publisher(for: .localModelDownloadProgressDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDownloadProgress() }
            .store(in: &subscriptions)
        session.$currentStep.dropFirst().sink { [weak self] step in
            if step != .speech, self?.testTask != nil || self?.authorizationTask != nil {
                self?.cancelTest()
            }
        }.store(in: &subscriptions)
        refreshDownloadProgress()
    }

    deinit {
        testTask?.cancel()
        authorizationTask?.cancel()
        downloadTask?.cancel()
        if let recorder, let audio = try? recorder.stop() {
            try? FileManager.default.removeItem(at: audio.fileURL)
        }
    }

    func selectProvider(_ provider: STTProvider) {
        guard provider != selectedProvider else { return }
        cancelTest()
        selectedProvider = provider
        session?.selectSpeechProvider(provider)
        syncCredentialsForSelectedProvider()
        refreshDownloadProgress()
    }

    func selectLocalModel(_ model: LocalSTTModel) {
        guard model != selectedLocalModel else { return }
        cancelTest()
        selectedLocalModel = model
        session?.settingsStore.localSTTModel = model
        session?.settingsStore.localSTTModelIdentifier = model.defaultModelIdentifier
        refreshDownloadProgress()
    }

    var isLocalModelAvailable: Bool { isModelAvailable(selectedLocalModel) }

    func isModelAvailable(_ model: LocalSTTModel) -> Bool {
        session?.localModelManager?.isModelAvailable(model) ?? false
    }

    private func refreshDownloadProgress() {
        isDownloading = false
        downloadProgress = 0
        switch LocalModelDownloadProgressCenter.shared.status {
        case let .downloading(model, progress) where model == selectedLocalModel:
            isDownloading = true
            downloadProgress = progress
        case let .failed(model, message) where model == selectedLocalModel && selectedProvider == .localModel:
            testStatus = .failure(message: message)
            canContinue = false
        default: break
        }
    }

    func startDownload() {
        guard !isDownloading, let manager = session?.localModelManager else { return }
        cancelTest()
        cancelDownload()
        let target = selectedLocalModel
        let token = downloadGeneration
        let config = LocalSTTConfiguration(model: target, modelIdentifier: target.defaultModelIdentifier,
                                           downloadSource: target.recommendedDownloadSource, autoSetup: true)
        isDownloading = true
        downloadProgress = 0.02
        LocalModelDownloadProgressCenter.shared.reportDownloading(model: target, progress: 0.02)
        downloadTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await manager.prepareModel(configuration: config) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, downloadGeneration == token else { return }
                        LocalModelDownloadProgressCenter.shared.reportDownloading(
                            model: target,
                            progress: update.progress
                        )
                    }
                }
                guard !Task.isCancelled, let self, downloadGeneration == token else { return }
                downloadGeneration = UUID()
                LocalModelDownloadProgressCenter.shared.clear()
                refreshDownloadProgress()
                objectWillChange.send()
            } catch {
                guard !Task.isCancelled, let self, downloadGeneration == token else { return }
                downloadGeneration = UUID()
                LocalModelDownloadProgressCenter.shared.reportFailed(model: target, message: error.localizedDescription)
                refreshDownloadProgress()
            }
        }
    }

    func cancelDownload() {
        downloadGeneration = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        LocalModelDownloadProgressCenter.shared.clear()
    }

    func refreshMicrophoneStatus() {
        let status = audioAuthorizationProvider()
        isMicrophoneDenied = status == .denied || status == .restricted
        isGoogleAuthorized = GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable()
    }

    func openSettings() {
        Task { await PrivacyGuard.openPermissionSettings(for: .microphone) }
    }

    func authorizeGoogleCloud() {
        guard !isAuthorizingGoogle else { return }
        isAuthorizingGoogle = true
        testStatus = .idle
        canContinue = false
        let authorize = authorizeGoogle
        authorizationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await authorize()
                guard !Task.isCancelled else { return }
                self?.isGoogleAuthorized = true
            } catch {
                guard !Task.isCancelled else { return }
                self?.testStatus = .failure(message: error.localizedDescription)
            }
            self?.isAuthorizingGoogle = false
        }
    }
}

extension OnboardingSpeechModel {
    func startHoldToTalk() {
        guard canTest, !isHolding, !isBusy else { return }
        cancelTest()
        isHolding = true
        isBusy = true
        let token = generation
        let authorization = audioAuthorizationProvider()
        let requestAccess = requestMicrophoneAccess
        let makeRecorder = makeRecorder
        testTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let granted = authorization == .notDetermined ? await requestAccess() : authorization == .authorized
            guard let self, generation == token, !Task.isCancelled else { return }
            isMicrophoneDenied = !granted
            // The system consent dialog ends the original pointer gesture.
            if authorization == .notDetermined {
                isHolding = false
                isBusy = false
                return
            }
            guard granted, isHolding else { isHolding = false; isBusy = false; return }
            commitCredentials()
            recordingSignature = configurationSignature
            let recorder = makeRecorder()
            do {
                try await recorder.startInBackground(levelHandler: { _ in }, audioBufferHandler: nil)
                guard generation == token, isHolding, !Task.isCancelled else {
                    Self.discardRecording(recorder)
                    if generation == token {
                        isBusy = false
                    }
                    return
                }
                self.recorder = recorder
                testStatus = .recording
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                isHolding = false
                isBusy = false
                testStatus = .failure(message: error.localizedDescription)
            }
        }
    }

    func stopHoldToTalk() {
        isHolding = false
        guard let recorder else { return }
        self.recorder = nil
        do {
            let audio = try recorder.stop()
            guard let signature = recordingSignature, signature == configurationSignature else {
                try? FileManager.default.removeItem(at: audio.fileURL)
                cancelTest()
                return
            }
            testStatus = .recognizing
            let token = generation
            let transcriber = makeTranscriber(selectedProvider)
            testTask = Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: audio.fileURL) }
                guard !Task.isCancelled else { return }
                let start = Date()
                do {
                    let preview = try await ConnectionTestSupport.runWithTimeout {
                        try await transcriber.transcribe(audioFile: audio)
                    }
                    guard !Task.isCancelled, let self, generation == token else { return }
                    guard configurationSignature == signature else { cancelTest(); return }
                    guard !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AskLocalError.message(L("workflow.transcription.noSpeech"))
                    }
                    testStatus = .success(preview: String(preview.prefix(120)),
                                          latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                    canContinue = true
                    isBusy = false
                    session?.settingsStore.onboardingSpeechDeferred = false
                } catch {
                    guard !Task.isCancelled, let self, generation == token else { return }
                    guard configurationSignature == signature else { cancelTest(); return }
                    testStatus = .failure(message: error.localizedDescription)
                    canContinue = false
                    isBusy = false
                }
            }
        } catch {
            testStatus = .failure(message: error.localizedDescription)
            isBusy = false
        }
    }

    func cancelRecordingIfActive() {
        if isHolding || recorder != nil {
            cancelTest()
        }
    }

    func cancelTest(cancelAuthorization: Bool = true) {
        generation = UUID()
        isHolding = false
        testTask?.cancel()
        testTask = nil
        if cancelAuthorization {
            authorizationTask?.cancel()
            authorizationTask = nil
            isAuthorizingGoogle = false
        }
        if let recorder {
            Self.discardRecording(recorder)
        }
        recorder = nil
        recordingSignature = nil
        testStatus = .idle
        canContinue = false
        isBusy = false
    }

    private static func discardRecording(_ recorder: any AudioRecorder) {
        if let audio = try? recorder.stop() {
            try? FileManager.default.removeItem(at: audio.fileURL)
        }
    }

    var canTest: Bool {
        if isMicrophoneDenied {
            return false
        }
        switch selectedProvider {
        case .localModel: return isLocalModelAvailable
        case .freeModel: return true
        case .googleCloud: return isGoogleAuthorized && !trimmed(googleProjectID).isEmpty
        case .doubaoRealtime: return !trimmed(doubaoAppID).isEmpty && !trimmed(doubaoAccessToken).isEmpty
        case .whisperAPI, .aliCloud, .groq, .soniox: return !trimmed(apiKey).isEmpty
        case .multimodalLLM:
            guard let store = session?.settingsStore else { return false }
            return !trimmed(store.multimodalLLMBaseURL).isEmpty && !trimmed(store.multimodalLLMModel).isEmpty
        default: return true
        }
    }

    private func credentialsChanged() {
        guard !isSyncing else { return }
        cancelTest(cancelAuthorization: false)
        commitCredentials()
    }

    private func syncCredentialsForSelectedProvider() {
        guard let store = session?.settingsStore else { return }
        isSyncing = true
        defer { isSyncing = false }
        googleProjectID = store.googleCloudProjectID
        doubaoAppID = store.doubaoAppID
        doubaoAccessToken = store.doubaoAccessToken
        whisperBaseURL = store.whisperBaseURL.isEmpty ? "https://api.openai.com/v1" : store.whisperBaseURL
        switch selectedProvider {
        case .aliCloud: apiKey = store.aliCloudAPIKey
        case .groq: apiKey = store.groqSTTAPIKey
        case .soniox: apiKey = store.sonioxAPIKey
        case .whisperAPI: apiKey = store.whisperAPIKey
        default: apiKey = ""
        }
    }

    func commitCredentials() {
        guard let store = session?.settingsStore else { return }
        // Do not clear deferral until an explicit test succeeds.
        switch selectedProvider {
        case .aliCloud: store.aliCloudAPIKey = trimmed(apiKey)
        case .groq: store.groqSTTAPIKey = trimmed(apiKey)
        case .soniox: store.sonioxAPIKey = trimmed(apiKey)
        case .whisperAPI:
            store.whisperAPIKey = trimmed(apiKey)
            store.whisperBaseURL = trimmed(whisperBaseURL)
        case .googleCloud: store.googleCloudProjectID = trimmed(googleProjectID)
        case .doubaoRealtime:
            store.doubaoAppID = trimmed(doubaoAppID)
            store.doubaoAccessToken = trimmed(doubaoAccessToken)
        default: break
        }
        store.sttProvider = selectedProvider
    }

    private var configurationSignature: [String] {
        guard let store = session?.settingsStore else { return [] }
        let fields: [String] = switch selectedProvider {
        case .localModel: [store.localSTTModel.rawValue, store.localSTTModelIdentifier]
        case .freeModel: [store.freeSTTModel]
        case .whisperAPI: [store.whisperBaseURL, store.whisperModel, store.whisperAPIKey]
        case .aliCloud: [store.aliCloudAPIKey, store.aliCloudModel]
        case .groq: [store.groqSTTAPIKey, store.groqSTTModel]
        case .soniox: [store.sonioxAPIKey, store.sonioxModel]
        case .doubaoRealtime: [store.doubaoAppID, store.doubaoAccessToken, store.doubaoResourceID]
        case .googleCloud: [store.googleCloudProjectID, store.googleCloudModel]
        case .multimodalLLM: [store.multimodalLLMBaseURL, store.multimodalLLMModel, store.multimodalLLMAPIKey]
        default: []
        }
        return [store.sttProvider.rawValue] + fields
    }

    var apiKeyHelpURL: URL? {
        switch selectedProvider {
        case .whisperAPI: URL(string: "https://platform.openai.com/api-keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .aliCloud: URL(string: "https://bailian.console.aliyun.com?tab=model#/api-key")
        case .soniox: URL(string: "https://console.soniox.com/")
        case .doubaoRealtime: URL(string: "https://www.volcengine.com/docs/6561/1354869?lang=zh")
        default: nil
        }
    }
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}
