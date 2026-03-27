import Foundation
import Speech

final class AppleSpeechTranscriber: Transcriber {
    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let auth = await MainActor.run { SFSpeechRecognizer.authorizationStatus() }
        guard auth == .authorized else {
            throw NSError(domain: "AppleSpeechTranscriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition not authorized"])
        }
        
        // Create recognizer on main thread
        let recognizer: SFSpeechRecognizer? = await MainActor.run {
            SFSpeechRecognizer()
        }
        
        guard let recognizer else {
            throw NSError(domain: "AppleSpeechTranscriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"])
        }

        let request = SFSpeechURLRecognitionRequest(url: audioFile.fileURL)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    hasResumed = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await onUpdate(TranscriptionSnapshot(text: text, isFinal: true))
                    }
                    continuation.resume(returning: text)
                }
            }
        }
    }
}
