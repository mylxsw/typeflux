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
    let autoModelDownloadService: AutoModelDownloadService
    let agentJobStore: AgentJobStore
    let agentExecutionRegistry: AgentExecutionRegistry
    let agentJobsWindowController: AgentJobsWindowController
    let mcpRegistry: MCPRegistry

    init() {
        hotkeyService = EventTapHotkeyService(settingsStore: settingsStore)
        audioRecorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: audioDeviceManager,
        )
        overlayController = OverlayController(appState: appState)
        clipboard = SystemClipboardService()
        askAnswerWindowController = AskAnswerWindowController(clipboard: clipboard, settingsStore: settingsStore)
        agentClarificationWindowController = AgentClarificationWindowController(settingsStore: settingsStore)
        soundEffectPlayer = SoundEffectPlayer(settingsStore: settingsStore)
        textInjector = AXTextInjector(settingsStore: settingsStore)
        Logger(subsystem: "dev.typeflux", category: "DIContainer").debug("DIContainer initialized — Logger test message")
        historyStore = SQLiteHistoryStore()
        agentJobStore = SQLiteAgentJobStore()
        agentExecutionRegistry = AgentExecutionRegistry()
        agentJobsWindowController = AgentJobsWindowController(
            settingsStore: settingsStore,
            jobStore: agentJobStore,
            executionRegistry: agentExecutionRegistry,
        )
        mcpRegistry = MCPRegistry()
        ollamaModelManager = OllamaLocalModelManager()
        llmAgentService = LLMAgentRouter(
            settingsStore: settingsStore,
            remote: OpenAICompatibleAgentService(settingsStore: settingsStore),
            ollama: OllamaAgentService(),
        )
        notificationService = SystemLocalNotificationService.shared
        localModelManager = LocalModelManager()
        autoModelDownloadService = AutoModelDownloadService(
            modelManager: localModelManager,
            settingsStore: settingsStore,
            notificationService: notificationService,
        )
        llmService = LLMRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleLLMService(settingsStore: settingsStore),
            ollama: OllamaLLMService(settingsStore: settingsStore, modelManager: ollamaModelManager),
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
            googleCloud: GoogleCloudSpeechTranscriber(),
            groq: WhisperAPITranscriber(
                settingsStore: settingsStore,
                baseURLOverride: "https://api.groq.com/openai/v1",
                apiKeyOverride: { [settingsStore] in settingsStore.groqSTTAPIKey },
                modelOverride: { [settingsStore] in settingsStore.groqSTTModel },
            ),
            typefluxOfficial: TypefluxOfficialTranscriber(),
            autoModelDownloadService: autoModelDownloadService,
        )
    }
}
