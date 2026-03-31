import Foundation

final class DIContainer {
    let appState = AppStateStore()
    let settingsStore = SettingsStore()
    let audioDeviceManager = AudioDeviceManager()

    // These must be initialized immediately, not lazily
    let hotkeyService: HotkeyService
    let audioRecorder: AudioRecorder
    let overlayController: OverlayController
    let soundEffectPlayer: SoundEffectPlayer
    let clipboard: ClipboardService
    let textInjector: TextInjector
    let historyStore: HistoryStore
    let llmService: LLMService
    let sttRouter: STTRouter
    let ollamaModelManager: OllamaLocalModelManager
    let localSTTServiceManager: LocalSTTServiceManager

    init() {
        hotkeyService = EventTapHotkeyService(settingsStore: settingsStore)
        audioRecorder = AVFoundationAudioRecorder(
            settingsStore: settingsStore,
            audioDeviceManager: audioDeviceManager
        )
        overlayController = OverlayController(appState: appState)
        soundEffectPlayer = SoundEffectPlayer(settingsStore: settingsStore)
        clipboard = SystemClipboardService()
        textInjector = AXTextInjector()
        historyStore = SQLiteHistoryStore()
        ollamaModelManager = OllamaLocalModelManager()
        localSTTServiceManager = LocalSTTServiceManager()
        llmService = LLMRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleLLMService(settingsStore: settingsStore),
            ollama: OllamaLLMService(settingsStore: settingsStore, modelManager: ollamaModelManager)
        )
        sttRouter = STTRouter(
            settingsStore: settingsStore,
            whisper: WhisperAPITranscriber(settingsStore: settingsStore),
            appleSpeech: AppleSpeechTranscriber(),
            localModel: LocalModelTranscriber(settingsStore: settingsStore, serviceManager: localSTTServiceManager),
            multimodal: MultimodalLLMTranscriber(settingsStore: settingsStore),
            aliCloud: AliCloudRealtimeTranscriber(settingsStore: settingsStore),
            doubaoRealtime: DoubaoRealtimeTranscriber(settingsStore: settingsStore)
        )
    }
}
