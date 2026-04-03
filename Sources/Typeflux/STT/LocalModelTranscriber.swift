import Foundation

final class LocalModelTranscriber: Transcriber {
    private let settingsStore: SettingsStore
    private let modelManager: LocalModelManager
    /// Cached WhisperKitTranscriber instances keyed by WhisperKit model name.
    /// WhisperKit loads CoreML models into memory on first use; caching avoids
    /// re-loading when the user transcribes multiple times with the same model.
    private var whisperKitCache: [String: WhisperKitTranscriber] = [:]

    init(settingsStore: SettingsStore, modelManager: LocalModelManager) {
        self.settingsStore = settingsStore
        self.modelManager = modelManager
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

        switch settingsStore.localSTTModel {
        case .whisperLocal:
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
            let transcriber = whisperKitTranscriber(for: model)
            return try await transcriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)

        case .senseVoiceSmall, .qwen3ASR:
            throw NSError(
                domain: "LocalModelTranscriber",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Native local speech inference is not yet available for \(settingsStore.localSTTModel.displayName). Please use a different STT provider."]
            )
        }
    }

    // MARK: - Private

    private func whisperKitTranscriber(for identifier: String) -> WhisperKitTranscriber {
        let modelName = identifier.hasPrefix("whisperkit-")
            ? String(identifier.dropFirst("whisperkit-".count))
            : identifier
        if let cached = whisperKitCache[modelName] { return cached }
        let transcriber = WhisperKitTranscriber(modelName: modelName)
        whisperKitCache[modelName] = transcriber
        return transcriber
    }

    private func vocabularyPromptText() -> String? {
        PromptCatalog.transcriptionVocabularyHint(terms: VocabularyStore.activeTerms())
    }
}

// MARK: - Pre-warm support

extension LocalModelTranscriber: RecordingPrewarmingTranscriber {
    /// Eagerly initialises the WhisperKit CoreML pipeline so the first
    /// real transcription call doesn't pay the cold-start penalty.
    func prepareForRecording() async {
        guard settingsStore.localSTTModel == .whisperLocal else { return }
        guard modelManager.preparedModelInfo(settingsStore: settingsStore) != nil else { return }
        let identifier = settingsStore.localSTTModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = identifier.isEmpty ? settingsStore.localSTTModel.defaultModelIdentifier : identifier
        let transcriber = whisperKitTranscriber(for: model)
        try? await transcriber.prepare()
    }

    func cancelPreparedRecording() async {
        // WhisperKit stays loaded in memory once initialised; nothing to cancel.
    }
}
