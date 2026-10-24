import Foundation

/// The workspace as it was when a round began, and whose workspace it is.
struct AskFileBaseline {
    let account: String
    let snapshot: Task<AskWorkspaceSnapshot, Never>
}

/// "Files changed this round": the conversation's `outputs/` and `work/` are snapshotted when
/// a round's first operation starts and compared when the round ends. The result is recorded
/// with the round's answer in `.typeflux/files.json`, so reloading history shows it again.
extension AskConversationModel {
    /// The round's first operation takes the baseline; operations that continue the same
    /// round (an approval, a credit resume) keep it. The scan reads file metadata and hashes
    /// only files changed since the last round, so it ends long before a model reply can run
    /// a tool.
    func beginFileTracking(_ id: String, account: String) {
        guard fileBaselines[id] == nil, let workspaces else { return }
        let previous = lastFileSnapshots[account + "\0" + id]
        let snapshot = Task.detached(priority: .userInitiated) {
            AskWorkspaceSnapshot.capture(root: workspaces.url(owner: account, conversationId: id), reusing: previous)
        }
        fileBaselines[id] = AskFileBaseline(account: account, snapshot: snapshot)
    }

    /// Records the round's changes once its run has ended. A run paused for a decision or
    /// for credits continues in a later operation, so its baseline stays.
    func finishFileTracking(_ id: String) {
        guard let baseline = fileBaselines[id] else { return }
        let conversation = (selectedId == id ? selected : nil) ?? snapshots[id]
        if conversation?.run?.isActive == true { return }
        fileBaselines[id] = nil
        guard let workspaces, let conversation, let round = Self.fileChangeRound(conversation) else { return }
        Task { [weak self] in
            let before = await baseline.snapshot.value
            let root = workspaces.url(owner: baseline.account, conversationId: id)
            let after = await Task.detached(priority: .utility) {
                AskWorkspaceSnapshot.capture(root: root, reusing: before)
            }.value
            self?.lastFileSnapshots[baseline.account + "\0" + id] = after
            let changes = Self.annotated(before.changes(to: after), calls: round.calls, root: root.path)
            // A conversation deleted meanwhile must not get its workspace back.
            guard !changes.isEmpty, self?.isDeletedConversation(id) == false else { return }
            do {
                try await workspaces.recordChanges(changes, messageId: round.answerId, owner: baseline.account,
                                                   conversationId: id)
            } catch {
                return
            }
            guard let self, fileChangesConversationId == id else { return }
            fileChanges[round.answerId] = Self.merged(fileChanges[round.answerId] ?? [], changes)
        }
    }

    /// Loads the recorded changes of the selected conversation.
    func loadFileChanges(_ id: String?) async {
        if fileChangesConversationId != id { fileChanges = [:] }
        fileChangesConversationId = id
        guard let id, let workspaces, let route = credentials(for: id) else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            workspaces.listChanges(owner: route.account, conversationId: id)
        }.value
        guard fileChangesConversationId == id else { return }
        fileChanges = loaded
    }

    /// The answer a round's changes belong to (its last assistant message after the last
    /// question; messages sent into the running run belong to the same round) and the
    /// round's tool calls.
    nonisolated static func fileChangeRound(_ conversation: AskConversation) -> (answerId: String, calls: [AskToolCall])? {
        let messages = conversation.messages
        let start = messages.lastIndex { $0.role == "user" && $0.steered != true }.map { $0 + 1 } ?? 0
        let round = messages[start...]
        guard let answer = round.last(where: { $0.role == "assistant" }) else { return nil }
        return (answer.id, round.flatMap { $0.toolCalls ?? [] })
    }

    /// Adds how the run's `files` tool changed each file.
    nonisolated static func annotated(_ changes: [AskWorkspaceFileChange], calls: [AskToolCall], root: String) -> [AskWorkspaceFileChange] {
        let counts = AskWorkspaceFileChange.toolCounts(calls, root: root)
        return changes.map { change in
            var value = change
            value.writes = counts[change.path]?.writes ?? 0
            value.edits = counts[change.path]?.edits ?? 0
            return value
        }
    }

    /// The same answer recorded again (a regenerated round) replaces paths it lists.
    nonisolated static func merged(_ existing: [AskWorkspaceFileChange], _ incoming: [AskWorkspaceFileChange]) -> [AskWorkspaceFileChange] {
        var byPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
        for change in incoming { byPath[change.path] = change }
        return byPath.values.sorted { $0.path < $1.path }
    }
}
