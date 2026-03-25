import Foundation

final class DIContainer {
    let appState = AppStateStore()
    let settingsStore = SettingsStore()

    // These must be initialized immediately, not lazily
    let hotkeyService: HotkeyService
    let audioRecorder: AudioRecorder
    let overlayController: OverlayController
    let clipboard: ClipboardService
    let textInjector: TextInjector
    let historyStore: HistoryStore
    let llmService: LLMService
    let sttRouter: STTRouter
    let ollamaModelManager: OllamaLocalModelManager

    init() {
        hotkeyService = EventTapHotkeyService(settingsStore: settingsStore)
        audioRecorder = AVFoundationAudioRecorder()
        overlayController = OverlayController(appState: appState)
        clipboard = SystemClipboardService()
        textInjector = AXTextInjector()
        historyStore = FileHistoryStore()
        ollamaModelManager = OllamaLocalModelManager()
        llmService = LLMRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleLLMService(settingsStore: settingsStore),
            ollama: OllamaLLMService(settingsStore: settingsStore, modelManager: ollamaModelManager)
        )
        sttRouter = STTRouter(
            settingsStore: settingsStore,
            whisper: WhisperAPITranscriber(settingsStore: settingsStore),
            appleSpeech: AppleSpeechTranscriber()
        )
    }
}
