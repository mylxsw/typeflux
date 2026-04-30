import Foundation

final class FunASRTranscriber: Transcriber {
    private let decoder: SherpaOnnxCommandLineDecoder

    init(
        modelIdentifier: String,
        modelFolder: String,
        processRunner: ProcessCommandRunning = ProcessCommandRunner(),
    ) {
        decoder = SherpaOnnxCommandLineDecoder(
            model: .funASR,
            modelIdentifier: modelIdentifier,
            modelFolder: modelFolder,
            processRunner: processRunner,
        )
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await decoder.decode(audioFile: audioFile)
    }
}
