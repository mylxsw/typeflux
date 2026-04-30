import Foundation

final class SenseVoiceTranscriber: Transcriber {
    private let decoder: SherpaOnnxCommandLineDecoder

    init(
        modelIdentifier: String,
        modelFolder: String,
        decodingConfiguration: SenseVoiceDecodingConfiguration = .default,
        processRunner: ProcessCommandRunning = ProcessCommandRunner(),
    ) {
        decoder = SherpaOnnxCommandLineDecoder(
            model: .senseVoiceSmall,
            modelIdentifier: modelIdentifier,
            modelFolder: modelFolder,
            senseVoiceDecodingConfiguration: decodingConfiguration,
            processRunner: processRunner,
        )
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await decoder.decode(audioFile: audioFile)
    }
}
