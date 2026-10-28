import Foundation

/// Emergency copy when the host cache channel is unavailable during quit.
enum AskQuitDraftBackup {
    static func save(_ draft: AskDraft, owner: String, key: String, url: URL) async throws {
        guard !owner.isEmpty, key.hasPrefix("saved-chat:"), draft.temporary != true else {
            throw AskRecoveryError.binding
        }
        let cache = try AskConversationCache(url: url)
        try await cache.saveDraft(draft, key: key, owner: owner)
        guard try await cache.draft(key: key, owner: owner) == draft else { throw AskRecoveryError.storage }
    }
}
