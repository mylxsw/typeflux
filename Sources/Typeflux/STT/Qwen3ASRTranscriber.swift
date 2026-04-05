import Foundation

final class Qwen3ASRTranscriber: Transcriber {
    private let decoder: SherpaOnnxCommandLineDecoder

    init(
        modelIdentifier: String,
        modelFolder: String,
        processRunner: ProcessCommandRunning = ProcessCommandRunner(),
    ) {
        decoder = SherpaOnnxCommandLineDecoder(
            model: .qwen3ASR,
            modelIdentifier: modelIdentifier,
            modelFolder: modelFolder,
            processRunner: processRunner,
        )
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await decoder.decode(audioFile: audioFile)
    }
}
