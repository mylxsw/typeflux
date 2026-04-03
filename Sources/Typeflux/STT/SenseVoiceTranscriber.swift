import Foundation

final class SenseVoiceTranscriber: Transcriber {
    private let decoder: SherpaOnnxCommandLineDecoder

    init(
        modelIdentifier: String,
        modelFolder: String,
        processRunner: ProcessCommandRunning = ProcessCommandRunner()
    ) {
        self.decoder = SherpaOnnxCommandLineDecoder(
            model: .senseVoiceSmall,
            modelIdentifier: modelIdentifier,
            modelFolder: modelFolder,
            processRunner: processRunner
        )
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await decoder.decode(audioFile: audioFile)
    }
}
