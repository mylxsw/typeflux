import Foundation
import WhisperKit

/// Transcribes audio using WhisperKit (on-device CoreML).
/// One instance per model name; the WhisperKit pipeline is lazily initialised
/// and cached across calls so the CoreML models stay loaded in memory.
final class WhisperKitTranscriber: Transcriber {
    private let modelName: String
    private var pipeline: WhisperKit?

    /// - Parameter modelName: WhisperKit model name, e.g. "small", "base", "large-v3".
    init(modelName: String) {
        self.modelName = modelName
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
        guard pipeline == nil else { return }
        onProgress?(0.1, "Initialising WhisperKit model \(modelName)…")
        let pipe = try await WhisperKit(WhisperKitConfig(model: modelName, verbose: false))
        pipeline = pipe
        onProgress?(1.0, "WhisperKit model \(modelName) is ready.")
    }

    // MARK: - Private

    private func ensurePipeline() async throws -> WhisperKit {
        if let p = pipeline { return p }
        let pipe = try await WhisperKit(WhisperKitConfig(model: modelName, verbose: false))
        pipeline = pipe
        return pipe
    }
}

