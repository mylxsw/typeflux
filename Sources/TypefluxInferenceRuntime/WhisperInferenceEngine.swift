import Foundation
import TypefluxInferenceProtocol
import WhisperKit

/// This is the only production WhisperKit pipeline constructor. This target is
/// linked by the helper, never by the application library.
public final class WhisperInferenceEngine: InferenceEngine, @unchecked Sendable {
    private var pipeline: WhisperKit?
    public init() {}

    public func prepare(_ configuration: InferenceConfiguration) async throws -> String? {
        try configuration.validate()
        let pipe = try await WhisperKit(WhisperKitConfig(
            model: configuration.model,
            downloadBase: configuration.downloadBase.map { URL(fileURLWithPath: $0) },
            modelRepo: configuration.repository, modelEndpoint: configuration.endpoint,
            modelFolder: configuration.modelFolder,
            tokenizerFolder: configuration.tokenizerFolder.map { URL(fileURLWithPath: $0) },
            verbose: false))
        pipeline = pipe
        return pipe.modelFolder?.path ?? configuration.modelFolder
    }

    public static func options(lowEnergy: Bool, language: String?) -> DecodingOptions {
        let language = lowEnergy ? language : nil
        return DecodingOptions(verbose: false, task: .transcribe, language: language,
                               usePrefillPrompt: true, detectLanguage: language == nil,
                               withoutTimestamps: true, noSpeechThreshold: lowEnergy ? 0.8 : 0.6)
    }

    public func transcribe(_ request: InferenceMessage,
                           progress: @escaping @Sendable (String) -> Bool) async throws -> String {
        guard let pipeline, let audioPath = request.audioPath else { throw InferenceFailure.unavailable }
        var options = Self.options(lowEnergy: request.lowEnergy, language: request.language)
        if request.lowEnergy, let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty, let tokenizer = pipeline.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await pipeline.transcribe(audioPath: audioPath, decodeOptions: options) {
            progress($0.text)
        }
        return (results.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
