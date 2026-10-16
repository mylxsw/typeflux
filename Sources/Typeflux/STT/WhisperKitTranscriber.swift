import Foundation
import TypefluxInferenceProtocol

/// Stable caller facade. All CoreML loading and decoding live in the independent
/// helper, including model preparation and automatic-download callers.
final class WhisperKitTranscriber: Transcriber, @unchecked Sendable {
    private let modelName: String
    private let modelFolder: String?
    private let resolvedPath: WhisperResolvedPath
    private let owner: WhisperWorkerOwner
    private let handle: ModuleHandle<WhisperWorkerClient>

    init(modelName: String, downloadBase: URL? = nil, modelRepo: String? = nil,
         modelEndpoint: String? = nil, modelFolder: String? = nil, tokenizerFolder: URL? = nil,
         pool: WhisperWorkerPool = .shared,
         factory: @escaping @Sendable (InferenceConfiguration, WhisperWorkerPool) throws -> WhisperWorkerClient = {
             try WhisperWorkerClient(configuration: $0, pool: $1)
         }) {
        self.modelName = modelName
        self.modelFolder = modelFolder
        let configuration = InferenceConfiguration(
            model: modelName, downloadBase: downloadBase?.path, repository: modelRepo, endpoint: modelEndpoint,
            modelFolder: modelFolder, tokenizerFolder: (tokenizerFolder ?? Self.defaultTokenizerFolder(for: modelFolder))?.path)
        let owner = WhisperWorkerOwner(), path = WhisperResolvedPath()
        self.owner = owner; resolvedPath = path
        handle = ModuleHandle(policy: ModulePolicy(startupTimeout: 1800, operationTimeout: 1800,
                                                   cleanupTimeout: 2, maxInFlight: 4, automaticallyRecover: false),
                              factory: {
            let client = try factory(configuration, pool)
            try owner.install(client)
            var request = InferenceMessage(kind: .prepare)
            request.configuration = configuration
            let reply = try await client.request(request)
            path.set(reply.modelPath)
            return client
        }, cleanup: { $0.stop() }, classify: { error in
            error as? InferenceFailure == .busy ? .operationOnly : .recover
        })
    }

    deinit { owner.stop() }
    func stop() { handle.preventNewWork(); owner.stop() }
    var isAvailableForReuse: Bool {
        guard owner.canReuse else { return false }
        switch handle.health.current?.state {
        case .degraded, .recovering, .circuitOpen, .disabled: return false
        default: return true
        }
    }
    var resolvedModelFolderPath: String? { resolvedPath.get() ?? modelFolder }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(audioFile: AudioFile, profile: TranscriptionProfile = .standard, prompt: String? = nil,
                          onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void) async throws -> String {
        let language = TranscriptionLanguageHints.preferredWhisperLanguageCode(preferredLanguages: Locale.preferredLanguages)
        let owner = self.owner
        do { return try await handle.perform { client in
            try await client.transcribe(audio: audioFile.fileURL, lowEnergy: profile == .lowEnergyRetry,
                                        prompt: prompt, language: language, deliverFinal: { text in
                try Task.checkCancellation()
                guard owner.permitsWork else { throw CancellationError() }
                await onUpdate(TranscriptionSnapshot(text: text, isFinal: true))
                try Task.checkCancellation()
                guard owner.permitsWork else { throw CancellationError() }
            }) {
                guard !Task.isCancelled, owner.permitsWork else { return }
                await onUpdate(TranscriptionSnapshot(text: $0, isFinal: false))
            }
        } } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LocalInferenceUnavailable()
        }
    }

    func prepare(onProgress: ((Double, String) -> Void)? = nil) async throws {
        onProgress?(0.1, L("localSTT.prepare.whisperInitializing", modelName))
        do {
            try await handle.perform { client in
                guard client.canReuse else { throw InferenceFailure.unavailable }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LocalInferenceUnavailable()
        }
        onProgress?(1.0, L("localSTT.prepare.whisperReady", modelName))
    }

    private static func defaultTokenizerFolder(for modelFolder: String?) -> URL? {
        guard let modelFolder else {
            return nil
        }

        var currentURL = URL(fileURLWithPath: modelFolder, isDirectory: true)
        while currentURL.path != "/" {
            if currentURL.lastPathComponent == "models" {
                return currentURL.deletingLastPathComponent()
            }
            currentURL.deleteLastPathComponent()
        }

        return nil
    }
}

extension WhisperKitTranscriber: LocalWhisperKitTranscribing {}
extension WhisperKitTranscriber: WhisperKitPreparing {}

private final class WhisperResolvedPath: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String?) { lock.withLock { self.value = value } }
    func get() -> String? { lock.withLock { value } }
}

/// Distinguishes native inference failure from a download-source failure. A
/// source fallback must not submit the same poisoned model to another worker.
struct LocalInferenceUnavailable: LocalizedError {
    var errorDescription: String? { L("localSTT.error.inferenceUnavailable") }
}
