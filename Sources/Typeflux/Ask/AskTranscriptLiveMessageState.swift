import Foundation

extension AskMessage {
    /// Empty assistant transport placeholders have no row and must not split tool groups.
    var hasTranscriptContent: Bool {
        role != "assistant" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(toolCalls ?? []).isEmpty || !(reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || image != nil || generatedImage != nil || !(attachments ?? []).isEmpty
            || diagnostic != nil
    }
}

/// The stream and durable snapshot arrive separately. Keep one visible message through
/// their handoff, bounded by the exact conversation, run and assistant step.
final class AskTranscriptLiveMessageState {
    private struct Scope: Equatable {
        var conversationID: String
        var runID: String
        var assistantID: String
    }
    private var scope: Scope?
    private var retained: AskMessage?

    func resolve(conversationID: String?, run: AskRun?, message: AskMessage?,
                 isCommitted: (String) -> Bool) -> AskMessage? {
        guard let conversationID, let run else {
            scope = nil; retained = nil
            return nil
        }
        let next = Scope(conversationID: conversationID, runID: run.id,
                         assistantID: run.assistantId ?? "live-" + run.id)
        if !run.isActive {
            scope = nil; retained = nil
            // Terminal snapshots may still carry an explicit preview; never retain a stale one.
            return message.flatMap {
                $0.id == next.assistantID && $0.runId == run.id && $0.hasTranscriptContent
                    && !isCommitted($0.id) ? $0 : nil
            }
        }
        if scope != next { scope = next; retained = nil }
        if isCommitted(next.assistantID) { retained = nil; return nil }
        if let message, message.id == next.assistantID, message.runId == run.id,
           message.hasTranscriptContent {
            retained = message
        }
        return retained
    }
}
