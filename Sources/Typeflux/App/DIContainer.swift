import Foundation

final class DIContainer {
    let appState = AppStateStore()
    let settingsStore = SettingsStore()
    let audioDeviceManager = AudioDeviceManager()

    // These must be initialized immediately, not lazily
    let hotkeyService: HotkeyService
    let audioRecorder: AudioRecorder
    let overlayController: OverlayController
    let askAnswerWindowController: AskAnswerWindowController
    let soundEffectPlayer: SoundEffectPlayer
    let clipboard: ClipboardService
    let textInjector: TextInjector
    let historyStore: HistoryStore
    let llmService: LLMService
    let llmAgentService: LLMAgentService
    let sttRouter: STTRouter
    let ollamaModelManager: OllamaLocalModelManager
    let localModelManager: LocalModelManager

    init() {
        hotkeyService = EventTapHotkeyService(settingsStore: settingsStore)
        audioRecorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: audioDeviceManager
        )
        overlayController = OverlayController(appState: appState)
        clipboard = SystemClipboardService()
        askAnswerWindowController = AskAnswerWindowController(clipboard: clipboard, settingsStore: settingsStore)
        soundEffectPlayer = SoundEffectPlayer(settingsStore: settingsStore)
        textInjector = AXTextInjector()
        historyStore = SQLiteHistoryStore()
        ollamaModelManager = OllamaLocalModelManager()
        llmAgentService = LLMAgentRouter(
            settingsStore: settingsStore,
            remote: OpenAICompatibleAgentService(settingsStore: settingsStore),
            ollama: OllamaAgentService()
        )
        localModelManager = LocalModelManager()
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
            doubaoRealtime: DoubaoRealtimeTranscriber(settingsStore: settingsStore)
        )
    }
}
