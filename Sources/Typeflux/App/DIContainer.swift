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
    let clipboardHistoryStore: ClipboardHistoryStore
    let conversationCache: RecoveringAskConversationCache
    let clipboardMonitor: ClipboardMonitor
    let clipboardPanelController: ClipboardPanelController
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
    let screenCapturePermission: any ScreenCapturePermissionProviding
    let screenCapture: any ScreenCapturing
    let imageTextRecognizer: any ImageTextRecognizing = VisionImageTextRecognizer()
    let screenshotOutput: any ScreenshotOutputting = ScreenshotOutput()
    /// Suggests mosaics over phone numbers, card numbers and the like, read on this Mac.
    lazy var sensitiveInfoScanner: any ScreenshotSensitiveInfoScanning = VisionSensitiveInfoScanner(
        recognizer: TiledImageTextRecognizer(base: imageTextRecognizer)
    )
    lazy var screenRecordingSessions: ScreenRecordingSessionController = {
        let sessions = ScreenRecordingSessionController(settings: settingsStore) { [unowned self] in
            ScreenRecordingCoordinator(permission: screenCapturePermission, capture: screenCapture,
                                       defaults: settingsStore.defaults,
                                       saveDirectory: { [settingsStore] in settingsStore.screenshotSaveDirectory })
        }
        sessions.isOtherCaptureActive = { [weak self] in self?.screenshotCoordinator.state != .idle }
        return sessions
    }()

    lazy var screenshotCoordinator: ScreenshotCoordinator = { [settingsStore, sensitiveInfoScanner] in
        // One store, so a style picked in the region editor is there in the long image editor too.
        let toolStyles = ScreenshotToolStyleStore(defaults: settingsStore.defaults)
        return ScreenshotCoordinator(
            capture: screenCapture,
            permission: screenCapturePermission,
            overlay: ScreenshotOverlayController(textMeasurer: VisionTextHeightMeasurer(),
                                                 sensitiveScanner: sensitiveInfoScanner, toolStyles: toolStyles),
            permissionGuide: ScreenshotPermissionGuideController(),
            toast: ScreenshotToastController(),
            output: screenshotOutput,
            saveDirectory: { settingsStore.screenshotSaveDirectory },
            relaunch: { ScreenshotAppRelauncher.relaunch() },
            longImageEditor: ScreenshotLongImageEditorController(textMeasurer: VisionTextHeightMeasurer(),
                                                                 sensitiveScanner: sensitiveInfoScanner,
                                                                 toolStyles: toolStyles),
            makeScrollCapture: ScreenshotCoordinator.scrollCapture(for:)
        )
    }()

    lazy var translationEngines = AskTranslationEngineFactory(settings: settingsStore, textProcessing: llmService)
    lazy var translationPanelModel: AskTranslationPanelModel = {
        let settings = settingsStore
        let factory = translationEngines
        let plugin = AskTranslatePlugin(onDevice: factory.engine(for: .device), ai: nil,
            wordBook: askConversationWindowController?.model.wordBook?.store,
            serviceSettings: { settings.askTranslationSettings }, fanout: factory.makeSession(),
            engines: { factory.engine(for: $0) }, serviceName: { factory.name(for: $0) },
            secondLanguage: { settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: $0) })
        let model = AskTranslationPanelModel(settings: settings, plugin: plugin, copy: { [clipboard] in clipboard.write(text: $0) })
        model.onSpeak = { AskSpeaker.shared.speak($0, language: $1) }
        model.onWordBook = { AskWordBookWindowController.shared.show(selecting: $0) }
        return model
    }()
    lazy var translationPanelController = AskTranslationPanelController(model: translationPanelModel)
    lazy var translationPanel = AskTranslationPanelCoordinator(model: translationPanelModel,
        controller: translationPanelController, injector: textInjector,
        recognizer: TiledImageTextRecognizer(base: imageTextRecognizer))

    lazy var askConversationWindowController: AskConversationWindowController? = {
        do { return try AskConversationWindowController(
            settings: settingsStore,
            injector: textInjector,
            registry: mcpRegistry,
            modelLibrary: modelLibrary,
            llmService: llmService,
            translationEngines: translationEngines,
            screenCapture: screenCapture,
            screenCapturePermission: screenCapturePermission,
            clipboardHistoryStore: clipboardHistoryStore,
            filePreviewLoader: AskFilePreviewLoader(),
            conversationCache: conversationCache
        ) } catch {
            ErrorLogStore.shared
                .log("Ask conversation storage could not be initialized: \(error.localizedDescription)"); return nil
        }
    }()

    // swiftlint:disable:next function_body_length
    init(conversationCacheFactory: @escaping @Sendable () throws -> any AskCaching = {
        try AskConversationCache(url: AskConversationCache.defaultURL())
    }) {
        conversationCache = RecoveringAskConversationCache(factory: conversationCacheFactory)
        modelLibrary = AskModelLibrary(defaults: settingsStore.defaults)
        let screenCapturePermission = ScreenCapturePermission.live
        self.screenCapturePermission = screenCapturePermission
        screenCapture = ScreenCaptureService(permission: screenCapturePermission)
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
        clipboardHistoryStore = SQLiteClipboardHistoryStore()
        SettingsWindowController.shared.clipboardHistoryStore = clipboardHistoryStore
        let settingsForClipboard = settingsStore
        clipboardMonitor = ClipboardMonitor(
            store: clipboardHistoryStore,
            isEnabled: { settingsForClipboard.clipboardHistoryEnabled },
            policy: { settingsForClipboard.clipboardCapturePolicy() },
            captureWorker: ClipboardCaptureWorker()
        )
        clipboardPanelController = ClipboardPanelController(settingsStore: settingsStore)
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
        // A test run's "run another keyword" types it into the launcher.
        AskWorkflowEditorWindowController.shared.openInLauncher = { [weak self] text in
            guard let controller = self?.askConversationWindowController else { return false }
            controller.model.finishPluginResult()
            controller.model.launcherDraft.text = text
            controller.showLauncher()
            return true
        }
    }
}
