import Foundation
import WhisperKit

/// Transcribes audio using WhisperKit (on-device CoreML).
/// One instance per model name; the WhisperKit pipeline is lazily initialised
/// and cached across calls so the CoreML models stay loaded in memory.
final class WhisperKitTranscriber: Transcriber {
    private let modelName: String
    private let downloadBase: URL?
    private let modelFolder: String?
    private let pipelineLock = NSLock()
    private var pipeline: WhisperKit?
    private var pipelineLoadTask: Task<WhisperKit, Error>?

    /// - Parameters:
    ///   - modelName: WhisperKit model name, e.g. "small", "base", "large-v3".
    ///   - downloadBase: Base directory where WhisperKit should download model snapshots.
    ///   - modelFolder: Existing local WhisperKit snapshot folder to load directly.
    init(modelName: String, downloadBase: URL? = nil, modelFolder: String? = nil) {
        self.modelName = modelName
        self.downloadBase = downloadBase
        self.modelFolder = modelFolder
    }

    var resolvedModelFolderPath: String? {
        pipelineLock.lock()
        let path = pipeline?.modelFolder?.path ?? modelFolder
        pipelineLock.unlock()
        return path
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let pipe = try await ensurePipeline()

        let language = AppLocalization.shared.language.whisperKitLanguageCode
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            withoutTimestamps: true
        )

        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioPath: audioFile.fileURL.path,
            decodeOptions: options
        ) { progress in
            // progress.text accumulates the partial transcript window by window
            let partial = progress.text
            if !partial.isEmpty {
                Task { await onUpdate(TranscriptionSnapshot(text: partial, isFinal: false)) }
            }
            return true // return false to cancel mid-transcription
        }

        let text = (results.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        await onUpdate(TranscriptionSnapshot(text: text, isFinal: true))
        return text
    }

    // MARK: - Preparation

    /// Downloads and initialises the WhisperKit pipeline.
    /// Safe to call before transcribing to pre-warm the model.
    /// - Parameter onProgress: Called with (0…1 progress, status message).
    func prepare(onProgress: ((Double, String) -> Void)? = nil) async throws {
        if currentPipeline() != nil {
            return
        }
        onProgress?(0.1, L("localSTT.prepare.whisperInitializing", modelName))
        _ = try await ensurePipeline()
        onProgress?(1.0, L("localSTT.prepare.whisperReady", modelName))
    }

    // MARK: - Private

    private func ensurePipeline() async throws -> WhisperKit {
        if let pipe = currentPipeline() {
            return pipe
        }

        let loadTask = pipelineInitializationTask()
        do {
            let pipe = try await loadTask.value

            storePipeline(pipe)

            return pipe
        } catch {
            clearPipelineLoadTask()
            throw error
        }
    }

    private func currentPipeline() -> WhisperKit? {
        pipelineLock.lock()
        let pipe = pipeline
        pipelineLock.unlock()
        return pipe
    }

    private func pipelineInitializationTask() -> Task<WhisperKit, Error> {
        pipelineLock.lock()
        if let existingTask = pipelineLoadTask {
            pipelineLock.unlock()
            return existingTask
        }

        let task = Task { [modelName, downloadBase, modelFolder] in
            try await WhisperKit(WhisperKitConfig(
                model: modelName,
                downloadBase: downloadBase,
                modelFolder: modelFolder,
                verbose: false
            ))
        }
        pipelineLoadTask = task
        pipelineLock.unlock()
        return task
    }

    private func storePipeline(_ pipe: WhisperKit) {
        pipelineLock.lock()
        pipeline = pipe
        pipelineLoadTask = nil
        pipelineLock.unlock()
    }

    private func clearPipelineLoadTask() {
        pipelineLock.lock()
        pipelineLoadTask = nil
        pipelineLock.unlock()
    }
}
