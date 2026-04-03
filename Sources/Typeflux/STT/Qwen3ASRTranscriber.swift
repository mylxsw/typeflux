import Foundation

final class Qwen3ASRTranscriber: Transcriber {
    private let modelIdentifier: String
    private let modelFolder: String

    init(modelIdentifier: String, modelFolder: String) {
        self.modelIdentifier = modelIdentifier
        self.modelFolder = modelFolder
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        _ = modelIdentifier
        _ = modelFolder
        _ = audioFile
        throw NSError(
            domain: "Qwen3ASRTranscriber",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: L(
                    "localSTT.error.runtimeUnavailable",
                    LocalSTTModel.qwen3ASR.displayName
                )
            ]
        )
    }
}
