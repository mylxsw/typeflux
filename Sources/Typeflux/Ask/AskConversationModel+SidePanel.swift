import Foundation

/// What the side panel's Files tab and file tabs read from the selected conversation.
extension AskConversationModel {
    /// The conversation's workspace and its files. Syncing first stores the uploads of a
    /// conversation opened from another device, as opening the folder in Finder did.
    func sidePanelFiles(_ id: String) async throws -> (root: URL, files: [AskWorkspaceFile])? {
        guard let workspaces, let route = credentials(for: id),
              let root = try await syncWorkspace(id) else { return nil }
        return (root, try await workspaces.listFiles(owner: route.account, conversationId: id))
    }

    func addSidePanelFiles(_ urls: [URL], conversationId id: String) async throws {
        guard let workspaces, let route = credentials(for: id) else { return }
        try await workspaces.addFiles(urls, owner: route.account, conversationId: id)
    }

    /// Folders a file tab may read: the conversation's workspace and the folders granted to it.
    func sidePanelRoots(_ id: String?) -> [String] {
        guard let id, let workspaces, let route = credentials(for: id) else { return [] }
        return [workspaces.url(owner: route.account, conversationId: id).path]
            + tools.temporaryFolders(conversationId: id).map(\.root)
    }

    /// The selected conversation's message ids, oldest first.
    var sidePanelMessageOrder: [String] { selected?.messages.map(\.id) ?? [] }

    /// The first line of the message a group of files came with.
    func sidePanelMessageTitle(_ messageId: String) -> String? {
        guard let message = selected?.messages.first(where: { $0.id == messageId }) else { return nil }
        let line = message.text.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : String(line.prefix(80))
    }
}
