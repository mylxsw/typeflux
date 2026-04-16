import Foundation

protocol LocalWhisperKitTranscribing: AnyObject {
    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String

    func prepare(onProgress: ((Double, String) -> Void)?) async throws
}

final class LocalModelTranscriber: Transcriber {
    static let defaultWhisperKitKeepAliveDuration: TimeInterval = 15 * 60

    private let settingsStore: SettingsStore
    private let modelManager: LocalSTTModelManaging
    private let whisperKitTranscriberFactory: (String, String) -> LocalWhisperKitTranscribing
    private let whisperKitKeepAliveDuration: TimeInterval
    private let whisperKitCacheLock = NSLock()
    /// Single active WhisperKit pipeline cache keyed by model name + resolved model folder.
    /// WhisperKit keeps CoreML graphs resident after the first load, so we drop stale
    /// entries on model switch to release memory from the previously selected model.
    private var whisperKitCache: [String: LocalWhisperKitTranscribing] = [:]
    private var whisperKitCacheExpirationTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        modelManager: LocalSTTModelManaging,
        whisperKitKeepAliveDuration: TimeInterval = defaultWhisperKitKeepAliveDuration,
        whisperKitTranscriberFactory: @escaping (String, String) -> LocalWhisperKitTranscribing = { modelName, modelFolder in
            WhisperKitTranscriber(modelName: modelName, modelFolder: modelFolder)
        },
    ) {
        self.settingsStore = settingsStore
        self.modelManager = modelManager
        self.whisperKitKeepAliveDuration = whisperKitKeepAliveDuration
        self.whisperKitTranscriberFactory = whisperKitTranscriberFactory
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
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
            """,
        )

        switch settingsStore.localSTTModel {
        case .whisperLocal:
            let modelInfo = try await preparedModelInfo()
            let transcriber = whisperKitTranscriber(for: model, modelFolder: modelInfo.storagePath)
            return try await transcriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)

        case .senseVoiceSmall:
            removeWhisperKitCache(keepingCapacity: false)
            let modelInfo = try await preparedModelInfo()
            let transcriber = SenseVoiceTranscriber(
                modelIdentifier: model,
                modelFolder: modelInfo.storagePath,
            )
            return try await transcriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)

        case .qwen3ASR:
            removeWhisperKitCache(keepingCapacity: false)
            let modelInfo = try await preparedModelInfo()
            let transcriber = Qwen3ASRTranscriber(
                modelIdentifier: model,
                modelFolder: modelInfo.storagePath,
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

        try await modelManager.prepareModel(settingsStore: settingsStore, onUpdate: nil)
        guard let prepared = modelManager.preparedModelInfo(settingsStore: settingsStore) else {
            throw preparedPathUnavailableError()
        }
        return prepared
    }

    private func whisperKitTranscriber(for identifier: String, modelFolder: String) -> LocalWhisperKitTranscribing {
        let modelName = identifier.hasPrefix("whisperkit-")
            ? String(identifier.dropFirst("whisperkit-".count))
            : identifier
        let cacheKey = "\(modelName)|\(modelFolder)"
        whisperKitCacheLock.lock()
        if let cached = whisperKitCache[cacheKey] {
            scheduleWhisperKitCacheExpiration(for: cacheKey)
            whisperKitCacheLock.unlock()
            return cached
        }

        whisperKitCache.removeAll(keepingCapacity: true)
        let transcriber = whisperKitTranscriberFactory(modelName, modelFolder)
        whisperKitCache[cacheKey] = transcriber
        scheduleWhisperKitCacheExpiration(for: cacheKey)
        whisperKitCacheLock.unlock()
        return transcriber
    }

    private func removeWhisperKitCache(keepingCapacity: Bool) {
        whisperKitCacheLock.lock()
        whisperKitCacheExpirationTask?.cancel()
        whisperKitCacheExpirationTask = nil
        whisperKitCache.removeAll(keepingCapacity: keepingCapacity)
        whisperKitCacheLock.unlock()
    }

    private func scheduleWhisperKitCacheExpiration(for cacheKey: String) {
        whisperKitCacheExpirationTask?.cancel()
        let keepAliveDuration = whisperKitKeepAliveDuration
        whisperKitCacheExpirationTask = Task { [weak self] in
            let nanoseconds = UInt64(max(keepAliveDuration, 0) * 1_000_000_000)
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            self?.expireWhisperKitCache(cacheKey: cacheKey)
        }
    }

    private func expireWhisperKitCache(cacheKey: String) {
        whisperKitCacheLock.lock()
        whisperKitCache.removeValue(forKey: cacheKey)
        if whisperKitCache.isEmpty {
            whisperKitCacheExpirationTask = nil
        }
        whisperKitCacheLock.unlock()
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
            userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.notPrepared")],
        )
    }

    private func preparedPathUnavailableError() -> NSError {
        NSError(
            domain: "LocalModelTranscriber",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.preparedPathUnavailable")],
        )
    }
}

// MARK: - Pre-warm support

extension LocalModelTranscriber: RecordingPrewarmingTranscriber {
    /// Eagerly initialises the WhisperKit CoreML pipeline so the first
    /// real transcription call doesn't pay the cold-start penalty.
    func prepareForRecording() async {
        guard settingsStore.localSTTModel == .whisperLocal else {
            removeWhisperKitCache(keepingCapacity: false)
            return
        }
        guard let modelInfo = modelManager.preparedModelInfo(settingsStore: settingsStore) else { return }
        let model = selectedModelIdentifier()
        let transcriber = whisperKitTranscriber(for: model, modelFolder: modelInfo.storagePath)
        try? await transcriber.prepare(onProgress: nil)
    }

    func cancelPreparedRecording() async {
        // WhisperKit stays loaded in memory once initialised; nothing to cancel.
    }
}
