import Foundation

extension STTRouter {
    var hasExplicitModelSelection: Bool {
        ModelRegistry.read(settingsStore.defaults) != nil
    }

    /// Custom scenes use their own provider credentials, independently of the Cloud plan.
    func transcribeSelectedModel(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        profile: TranscriptionProfile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let provider = selectedTranscriber
        if let optimized = provider as? ASROptimizeAwareTranscriber {
            return try await optimized.transcribeStream(
                audioFile: audioFile,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate
            )
        }
        if let scenarioAware = provider as? TypefluxCloudScenarioAwareTranscriber {
            return try await scenarioAware.transcribeStream(
                audioFile: audioFile,
                scenario: scenario,
                onUpdate: onUpdate
            )
        }
        if let profileAware = provider as? TranscriptionProfileAwareTranscriber {
            return try await profileAware.transcribeStream(audioFile: audioFile, profile: profile, onUpdate: onUpdate)
        }
        return try await provider.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
    }

    private var selectedTranscriber: Transcriber {
        switch settingsStore.sttProvider {
        case .freeModel: freeSTT
        case .whisperAPI: whisper
        case .appleSpeech: appleSpeech
        case .localModel: localModel
        case .multimodalLLM: multimodal
        case .aliCloud: aliCloud
        case .doubaoRealtime: doubaoRealtime
        case .googleCloud: googleCloud
        case .groq: groq
        case .soniox: soniox
        case .typefluxOfficial: typefluxOfficial
        }
    }
}
