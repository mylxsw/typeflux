import Foundation

/// A displaced, unsent workspace draft; it is not a conversation history entry.
struct AskSavedChatDraft: Identifiable, Equatable, Sendable {
    var id: String
    var draft: AskDraft
}

extension AskDraft {
    /// Captured selections and screenshots alone never initiate a new chat.
    var hasChatInput: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(attachments ?? []).isEmpty || !(references ?? []).isEmpty
            || !(skills ?? []).isEmpty || !(mcpServers ?? []).isEmpty
    }
}
