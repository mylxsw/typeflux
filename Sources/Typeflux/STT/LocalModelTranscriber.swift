import Foundation

final class LocalModelTranscriber: Transcriber {
    private let settingsStore: SettingsStore
    private let modelManager: LocalModelManager
    private let fallbackTranscriber: Transcriber

    init(
        settingsStore: SettingsStore,
        modelManager: LocalModelManager,
        fallbackTranscriber: Transcriber = AppleSpeechTranscriber()
    ) {
        self.settingsStore = settingsStore
        self.modelManager = modelManager
        self.fallbackTranscriber = fallbackTranscriber
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let model = settingsStore.localSTTModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settingsStore.localSTTModel.defaultModelIdentifier
            : settingsStore.localSTTModelIdentifier
        NetworkDebugLogger.logRequest(
            URLRequest(url: audioFile.fileURL),
            bodyDescription: """
            {
              "provider": "\(settingsStore.localSTTModel.rawValue)",
              "model": "\(model)",
              "mode": "native",
              "prompt": "\(vocabularyPromptText() ?? "")",
              "file": {
                "path": "\(audioFile.fileURL.path)"
              }
            }
            """
        )

        if modelManager.preparedModelInfo(settingsStore: settingsStore) == nil {
            guard settingsStore.localSTTAutoSetup else {
                throw NSError(
                    domain: "LocalModelTranscriber",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Local STT model is not ready. Prepare it in Settings first."]
                )
            }
            try await modelManager.prepareModel(settingsStore: settingsStore)
        }

        let text = try await fallbackTranscriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        NetworkDebugLogger.logMessage(
            "Local native transcription finished with provider \(settingsStore.localSTTModel.rawValue) and model \(model)"
        )
        return text
    }

    private func vocabularyPromptText() -> String? {
        PromptCatalog.transcriptionVocabularyHint(terms: VocabularyStore.activeTerms())
    }
}
