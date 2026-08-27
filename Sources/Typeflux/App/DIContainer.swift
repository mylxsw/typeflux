import Foundation
import os

@MainActor
final class DIContainer {
    let appState = AppStateStore()
    let settingsStore = SettingsStore()
    let audioDeviceManager = AudioDeviceManager()

    // These must be initialized immediately, not lazily
    let hotkeyService: HotkeyService
    let audioRecorder: AudioRecorder
    let overlayController: OverlayController
    let askAnswerWindowController: AskAnswerWindowController
    let agentClarificationWindowController: AgentClarificationWindowController
    let soundEffectPlayer: SoundEffectPlayer
    let clipboard: ClipboardService
    let textInjector: TextInjector
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
    let agentJobStore: AgentJobStore
    let agentExecutionRegistry: AgentExecutionRegistry
    let agentJobsWindowController: AgentJobsWindowController
    let mcpRegistry: MCPRegistry
    let cloudLoginSyncCoordinator: CloudLoginSyncCoordinator
    let cloudDataSyncCoordinator: CloudDataSyncCoordinator
    let outputPostProcessor: OutputPostProcessing

    // swiftlint:disable:next function_body_length
    init() {
        hotkeyService = EventTapHotkeyService(settingsStore: settingsStore)
        audioRecorder = AVFoundationAudioRecorder(
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
        agentClarificationWindowController = AgentClarificationWindowController(settingsStore: settingsStore)
        soundEffectPlayer = SoundEffectPlayer(settingsStore: settingsStore)
        textInjector = AXTextInjector(settingsStore: settingsStore)
        Logger(subsystem: "ai.gulu.app.typeflux", category: "DIContainer")
            .debug("DIContainer initialized — Logger test message")
        historyStore = SQLiteHistoryStore()
        agentJobStore = SQLiteAgentJobStore()
        agentExecutionRegistry = AgentExecutionRegistry()
        agentJobsWindowController = AgentJobsWindowController(
            settingsStore: settingsStore,
            jobStore: agentJobStore,
            executionRegistry: agentExecutionRegistry
        )
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
    }
}
