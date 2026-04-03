import Foundation

final class LocalModelTranscriber: Transcriber {
    private let settingsStore: SettingsStore
    private let modelManager: LocalModelManager
    /// Single active WhisperKit pipeline cache keyed by model name + resolved model folder.
    /// WhisperKit keeps CoreML graphs resident after the first load, so we drop stale
    /// entries on model switch to release memory from the previously selected model.
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
        let model = selectedModelIdentifier()
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
            let modelInfo = try await preparedModelInfo()
            let transcriber = whisperKitTranscriber(for: model, modelFolder: modelInfo.storagePath)
            return try await transcriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)

        case .senseVoiceSmall:
            whisperKitCache.removeAll(keepingCapacity: false)
            let modelFolder = modelManager.storagePath(
                for: LocalSTTConfiguration(settingsStore: settingsStore)
            )
            let transcriber = SenseVoiceTranscriber(
                modelIdentifier: model,
                modelFolder: modelFolder
            )
            return try await transcriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)

        case .qwen3ASR:
            whisperKitCache.removeAll(keepingCapacity: false)
            let modelFolder = modelManager.storagePath(
                for: LocalSTTConfiguration(settingsStore: settingsStore)
            )
            let transcriber = Qwen3ASRTranscriber(
                modelIdentifier: model,
                modelFolder: modelFolder
            )
            return try await transcriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        }
    }

    // MARK: - Private

    private func preparedModelInfo() async throws -> LocalSTTPreparedModelInfo {
        if let prepared = modelManager.preparedModelInfo(settingsStore: settingsStore) {
            return prepared
        }

        guard settingsStore.localSTTAutoSetup else {
            throw notPreparedError()
        }

        try await modelManager.prepareModel(settingsStore: settingsStore)
        guard let prepared = modelManager.preparedModelInfo(settingsStore: settingsStore) else {
            throw preparedPathUnavailableError()
        }
        return prepared
    }

    private func whisperKitTranscriber(for identifier: String, modelFolder: String) -> WhisperKitTranscriber {
        let modelName = identifier.hasPrefix("whisperkit-")
            ? String(identifier.dropFirst("whisperkit-".count))
            : identifier
        let cacheKey = "\(modelName)|\(modelFolder)"
        if let cached = whisperKitCache[cacheKey] { return cached }

        whisperKitCache.removeAll(keepingCapacity: true)
        let transcriber = WhisperKitTranscriber(modelName: modelName, modelFolder: modelFolder)
        whisperKitCache[cacheKey] = transcriber
        return transcriber
    }

    private func vocabularyPromptText() -> String? {
        PromptCatalog.transcriptionVocabularyHint(terms: VocabularyStore.activeTerms())
    }

    private func selectedModelIdentifier() -> String {
        let identifier = settingsStore.localSTTModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? settingsStore.localSTTModel.defaultModelIdentifier : identifier
    }

    private func notPreparedError() -> NSError {
        NSError(
            domain: "LocalModelTranscriber",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.notPrepared")]
        )
    }

    private func preparedPathUnavailableError() -> NSError {
        NSError(
            domain: "LocalModelTranscriber",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.preparedPathUnavailable")]
        )
    }
}

// MARK: - Pre-warm support

extension LocalModelTranscriber: RecordingPrewarmingTranscriber {
    /// Eagerly initialises the WhisperKit CoreML pipeline so the first
    /// real transcription call doesn't pay the cold-start penalty.
    func prepareForRecording() async {
        guard settingsStore.localSTTModel == .whisperLocal else {
            whisperKitCache.removeAll(keepingCapacity: false)
            return
        }
        guard let modelInfo = modelManager.preparedModelInfo(settingsStore: settingsStore) else { return }
        let model = selectedModelIdentifier()
        let transcriber = whisperKitTranscriber(for: model, modelFolder: modelInfo.storagePath)
        try? await transcriber.prepare()
    }

    func cancelPreparedRecording() async {
        // WhisperKit stays loaded in memory once initialised; nothing to cancel.
    }
}
