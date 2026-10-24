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

    /// Copies files into `inputs/`. Files already in the workspace, such as a row dragged
    /// back onto the panel, are not copied again.
    func addSidePanelFiles(_ urls: [URL], conversationId id: String) async throws {
        guard let workspaces, let route = credentials(for: id) else { return }
        let root = workspaces.url(owner: route.account, conversationId: id)
        let outside = urls.filter { !Self.isInside($0, root: root) }
        guard !outside.isEmpty else { return }
        try await workspaces.addFiles(outside, owner: route.account, conversationId: id)
    }

    /// "Reference in message": a workspace file joins the composer's attachments, as if the
    /// user had attached it, and rides with the next message. Nothing happens once the user
    /// has moved to another conversation or the file is attached already.
    func referenceSidePanelFile(_ url: URL, conversationId id: String) {
        guard selectedId == id else { return }
        let path = AskProjectFileAccess.normalizedRoot(url.path)
        let attached = (draft.attachments ?? []).compactMap(\.localSourcePath).map(AskProjectFileAccess.normalizedRoot)
        guard !attached.contains(path) else { return }
        addAttachments([.file(URL(fileURLWithPath: path))], launcher: false)
    }

    nonisolated static func isInside(_ url: URL, root: URL) -> Bool {
        let base = AskProjectFileAccess.normalizedRoot(root.path)
        let path = AskProjectFileAccess.normalizedRoot(url.path)
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
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

    /// Resolves a workspace path for a file tab. A file the workspace lacks yet, such as an
    /// upload from another device, is looked for again after syncing the workspace.
    func sidePanelTarget(_ path: String, conversationId id: String) async throws -> AskSidePanelFileAccess.Target {
        func resolve() throws -> AskSidePanelFileAccess.Target {
            let roots = sidePanelRoots(id)
            guard let workspace = roots.first else { throw AskSidePanelFileAccess.AccessError.denied }
            return try AskSidePanelFileAccess.resolve(path, workspaceRoot: URL(fileURLWithPath: workspace),
                                                      grantedRoots: Array(roots.dropFirst()))
        }
        do {
            return try resolve()
        } catch let error as AskSidePanelFileAccess.AccessError where error != .tooLarge && !path.hasPrefix("/") {
            _ = try await syncWorkspace(id)
            return try resolve()
        }
    }

    /// The file's URL for opening it outside Typeflux; only plain paths inside the workspace.
    func sidePanelFileURL(_ path: String, conversationId id: String?) -> URL? {
        guard let workspace = sidePanelRoots(id).first,
              AskWorkspaceFileChange.workspacePath(path, root: workspace) == path else { return nil }
        return URL(fileURLWithPath: workspace).appendingPathComponent(path)
    }

    /// Scrolls the transcript to a message and highlights it for a moment.
    func locateMessage(_ id: String) {
        referenceLocation = id
        highlightedMessageId = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, highlightedMessageId == id else { return }
            highlightedMessageId = nil
        }
    }
}
