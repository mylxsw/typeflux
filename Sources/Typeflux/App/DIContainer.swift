import Foundation
import os

@MainActor
final class DIContainer {
    let appState = AppStateStore()
    let settingsStore = SettingsStore()
    let modelLibrary: AskModelLibrary
    let audioDeviceManager = AudioDeviceManager()

    // These must be initialized immediately, not lazily
    let hotkeyService: HotkeyService
    let audioRecorder: AudioRecorder
    let overlayController: OverlayController
    let askAnswerWindowController: AskAnswerWindowController
    let soundEffectPlayer: SoundEffectPlayer
    let clipboard: ClipboardService
    let textInjector: AXTextInjector
    let historyStore: HistoryStore
    let llmService: LLMService
    let llmAgentService: LLMAgentService
    let sttRouter: STTRouter
    let notificationService: LocalNotificationSending
    let ollamaModelManager: OllamaLocalModelManager
    let localModelManager: LocalModelManager
    let bundledModelAutoSetup: BundledModelAutoSetup
    let autoModelDownloadService: AutoModelDownloadService
    let analyticsReporter: AnalyticsEventReporting
    let permissionStatusAnalyticsMonitor: PermissionStatusAnalyticsMonitor
    let usageDailySummaryReporter: UsageDailySummaryReporter
    let mcpRegistry: MCPRegistry
    let cloudLoginSyncCoordinator: CloudLoginSyncCoordinator
    let cloudDataSyncCoordinator: CloudDataSyncCoordinator
    let outputPostProcessor: OutputPostProcessing
    lazy var askConversationWindowController: AskConversationWindowController? = {
        do { return try AskConversationWindowController(
            settings: settingsStore,
            injector: textInjector,
            registry: mcpRegistry,
            modelLibrary: modelLibrary,
            llmService: llmService
        ) } catch {
            ErrorLogStore.shared
                .log("Ask conversation storage could not be initialized: \(error.localizedDescription)"); return nil
        }
    }()

    // swiftlint:disable:next function_body_length
    init() {
        modelLibrary = AskModelLibrary(defaults: settingsStore.defaults)
        SettingsWindowController.shared.modelLibrary = modelLibrary
        hotkeyService = EventTapHotkeyService(settingsStore: settingsStore)
        audioRecorder = SwitchableAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: audioDeviceManager
        )
        overlayController = OverlayController(appState: appState, settingsStore: settingsStore)
        clipboard = SystemClipboardService()
        outputPostProcessor = OpenCCOutputPostProcessor(settingsStore: settingsStore)
        askAnswerWindowController = AskAnswerWindowController(
            clipboard: clipboard,
            settingsStore: settingsStore,
            outputPostProcessor: outputPostProcessor
        )
        soundEffectPlayer = SoundEffectPlayer(settingsStore: settingsStore)
        textInjector = AXTextInjector()
        Logger(subsystem: "ai.gulu.app.typeflux", category: "DIContainer")
            .debug("DIContainer initialized — Logger test message")
        historyStore = SQLiteHistoryStore()
        mcpRegistry = MCPRegistry()
        analyticsReporter = SettingsAwareAnalyticsEventReporter(settingsStore: settingsStore)
        permissionStatusAnalyticsMonitor = PermissionStatusAnalyticsMonitor(
            defaults: settingsStore.defaults,
            reporter: analyticsReporter
        )
        usageDailySummaryReporter = UsageDailySummaryReporter(
            defaults: settingsStore.defaults,
            reporter: analyticsReporter
        )
        ollamaModelManager = OllamaLocalModelManager(analyticsReporter: analyticsReporter)
        llmAgentService = LLMAgentRouter(
            settingsStore: settingsStore,
            remote: OpenAICompatibleAgentService(settingsStore: settingsStore),
            ollama: OllamaAgentService()
        )
        notificationService = SystemLocalNotificationService.shared
        cloudLoginSyncCoordinator = CloudLoginSyncCoordinator(settingsStore: settingsStore)
        cloudDataSyncCoordinator = CloudDataSyncCoordinator.shared
        localModelManager = LocalModelManager(analyticsReporter: analyticsReporter)
        bundledModelAutoSetup = BundledModelAutoSetup(linker: localModelManager)
        autoModelDownloadService = AutoModelDownloadService(
            modelManager: localModelManager,
            settingsStore: settingsStore,
            notificationService: notificationService
        )
        llmService = LLMRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleLLMService(settingsStore: settingsStore),
            ollama: OllamaLLMService(settingsStore: settingsStore, modelManager: ollamaModelManager)
        )
        sttRouter = STTRouter(
            settingsStore: settingsStore,
            whisper: WhisperAPITranscriber(settingsStore: settingsStore),
            freeSTT: FreeSTTTranscriber(settingsStore: settingsStore),
            appleSpeech: AppleSpeechTranscriber(),
            localModel: LocalModelTranscriber(settingsStore: settingsStore, modelManager: localModelManager),
            multimodal: MultimodalLLMTranscriber(settingsStore: settingsStore),
            aliCloud: AliCloudRealtimeTranscriber(settingsStore: settingsStore),
            doubaoRealtime: DoubaoRealtimeTranscriber(settingsStore: settingsStore),
            googleCloud: GoogleCloudSpeechTranscriber(settingsStore: settingsStore),
            groq: WhisperAPITranscriber(
                settingsStore: settingsStore,
                baseURLOverride: "https://api.groq.com/openai/v1",
                apiKeyOverride: { [settingsStore] in settingsStore.groqSTTAPIKey },
                modelOverride: { [settingsStore] in settingsStore.groqSTTModel }
            ),
            soniox: SonioxTranscriber(settingsStore: settingsStore),
            typefluxOfficial: TypefluxOfficialTranscriber(),
            typefluxCloudLoginFallbackLocalModel: DefaultSenseVoiceFallbackTranscriber(
                modelManager: localModelManager
            ),
            autoModelDownloadService: autoModelDownloadService
        )
        let settings = settingsStore
        // The workflow assistant's conversations are ordinary Ask conversations.
        AskWorkflowEditorWindowController.shared.assistantDependencies = { [weak self] in
            guard let model = self?.askConversationWindowController?.model else { return nil }
            return .init(api: model.api, session: { model.session() ?? (AskRoutedAPI.localOwner, "") },
                         deviceId: model.deviceId, modelLibrary: model.modelLibrary, inference: model.customInference,
                         prefersLocal: { settings.askNewConversationsStayLocal }, defaults: settings.defaults)
        }
    }
}
