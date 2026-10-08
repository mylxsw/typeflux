import Foundation

extension AskConversationModel {
    /// Merges listed cloud titles with account-scoped cached and local conversations.
    /// No network call is made as a launcher query changes.
    func launcherChatHistory() async -> AskHistoryPlugin.Snapshot {
        guard let current = session(), owner.isEmpty || owner == current.owner else { return .empty }
        let account = owner
        let cached = (try? await cache.list(owner: current.owner)) ?? []
        let local = current.token.isEmpty ? [] : (try? await cache.list(owner: AskRoutedAPI.localOwner)) ?? []
        guard !Task.isCancelled, owner == account, session()?.owner == current.owner else { return .empty }
        // Establish the first account without clearing the launcher's typed query.
        if owner.isEmpty { owner = current.owner }
        registerLocalHistory(local)
        var byID: [String: AskConversationSummary] = [:]
        for item in cached + local + conversations where !isDeletedConversation(item.id) {
            if let existing = byID[item.id], existing.updatedAt > item.updatedAt { continue }
            byID[item.id] = item
        }
        return .init(account: current.owner, conversations: byID.values.sorted { $0.updatedAt > $1.updatedAt })
    }
}
