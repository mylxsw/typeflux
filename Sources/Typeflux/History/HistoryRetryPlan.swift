import Foundation

enum HistoryRetryPlan: Equatable {
    case retranscribe(audioURL: URL)
    case rewriteSelection(sourceText: String, personaPrompt: String)
    case rewriteTranscript(sourceText: String, personaPrompt: String)
    case presentResult(String)
    case unavailable(HistoryRetryUnavailableReason)

    var isAvailable: Bool {
        if case .unavailable = self {
            return false
        }
        return true
    }
}

enum HistoryRetryUnavailableReason: Equatable {
    case audioMissing
    case audioGone
}

enum HistoryRetryPlanner {
    static func plan(
        for record: HistoryRecord,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> HistoryRetryPlan {
        if record.applyStatus == .failed,
           let finalText = nonEmpty(record.finalText) {
            return .presentResult(finalText)
        }

        if record.mode == .editSelection,
           record.recordingStatus == .skipped,
           record.transcriptionStatus == .skipped,
           let sourceText = nonEmpty(record.selectionOriginalText),
           let personaPrompt = nonEmpty(record.personaPrompt) {
            return .rewriteSelection(sourceText: sourceText, personaPrompt: personaPrompt)
        }

        if record.mode == .personaRewrite || record.mode == .dictation,
           let transcriptText = nonEmpty(record.transcriptText),
           let personaPrompt = nonEmpty(record.personaPrompt) {
            return .rewriteTranscript(sourceText: transcriptText, personaPrompt: personaPrompt)
        }

        guard let audioFilePath = nonEmpty(record.audioFilePath) else {
            return .unavailable(.audioMissing)
        }
        guard fileExists(audioFilePath) else {
            return .unavailable(.audioGone)
        }
        return .retranscribe(audioURL: URL(fileURLWithPath: audioFilePath))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
