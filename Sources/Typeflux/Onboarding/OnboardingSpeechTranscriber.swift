import Foundation

/// Use the selected engine directly: a failed onboarding test must not silently succeed via a fallback.
@MainActor
enum OnboardingSpeechTranscriber {
    static func make(_ provider: STTProvider, settings: SettingsStore,
                     manager: any LocalSTTModelManaging) -> any Transcriber {
        switch provider {
        case .localModel: LocalModelTranscriber(settingsStore: settings, modelManager: manager)
        case .appleSpeech: AppleSpeechTranscriber()
        case .multimodalLLM: MultimodalLLMTranscriber(settingsStore: settings)
        default: remote(provider, settings: settings)
        }
    }

    private static func remote(_ provider: STTProvider, settings: SettingsStore) -> any Transcriber {
        switch provider {
        case .freeModel: FreeSTTTranscriber(settingsStore: settings)
        case .whisperAPI: WhisperAPITranscriber(settingsStore: settings)
        case .aliCloud: AliCloudRealtimeTranscriber(settingsStore: settings)
        case .doubaoRealtime: DoubaoRealtimeTranscriber(settingsStore: settings)
        case .googleCloud: GoogleCloudSpeechTranscriber(settingsStore: settings)
        case .groq:
            WhisperAPITranscriber(settingsStore: settings, baseURLOverride: "https://api.groq.com/openai/v1",
                                  apiKeyOverride: { settings.groqSTTAPIKey }, modelOverride: { settings.groqSTTModel })
        case .soniox: SonioxTranscriber(settingsStore: settings)
        case .typefluxOfficial: TypefluxOfficialTranscriber()
        default: preconditionFailure("Expected a remote speech provider")
        }
    }
}
