import AppKit

extension AskConversationModel {
    @discardableResult
    func syncWorkspace(_ id: String, requireFresh: Bool = false) async throws -> URL? {
        guard let workspaces, let route = credentials(for: id) else { return nil }
        var snapshot: AskConversation?
        if requireFresh {
            snapshot = try await api.conversation(id: id, token: route.token)
        } else {
            snapshot = snapshots[id]
            if snapshot == nil { snapshot = try await cache.load(id: id, owner: route.owner) }
            if snapshot == nil { snapshot = try await api.conversation(id: id, token: route.token) }
        }
        if let snapshot {
            try await workspaces.saveConversation(snapshot, owner: route.account)
            for message in snapshot.messages where message.role == "user" {
                try await workspaces.captureInputs(message.attachments ?? [], image: message.image,
                                                   messageId: message.id, owner: route.account,
                                                   conversationId: id)
            }
        }
        return try await workspaces.ensure(owner: route.account, conversationId: id)
    }
}
