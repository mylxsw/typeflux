import Foundation

/// Sends everything cached for the temporary conversation to an in-memory store,
/// so its snapshots, drafts and tool journal never reach the disk. Other owners
/// use the persistent cache unchanged.
struct AskTemporaryCache: AskCaching {
    let base: any AskCaching
    let temporary: any AskCaching

    init(base: any AskCaching, temporary: (any AskCaching)? = nil) {
        self.base = base
        // An in-memory SQLite database cannot fail for lack of disk space or permissions.
        self.temporary = temporary ?? (try? AskConversationCache.inMemory()) ?? AskDiscardingCache()
    }

    private func store(_ owner: String) -> any AskCaching {
        owner == AskRoutedAPI.temporaryOwner ? temporary : base
    }

    func execution(id: String, owner: String) async throws -> AskExecutionEntry? {
        try await store(owner).execution(id: id, owner: owner)
    }

    func executions(conversationId: String, owner: String) async throws -> [AskExecutionEntry] {
        try await store(owner).executions(conversationId: conversationId, owner: owner)
    }

    func claimExecution(_ audit: AskExecutionAudit, owner: String) async throws -> Bool {
        try await store(owner).claimExecution(audit, owner: owner)
    }

    func saveRejectedToolReceipt(audit: AskExecutionAudit, receipt: AskToolResultRequest, owner: String) async throws {
        try await store(owner).saveRejectedToolReceipt(audit: audit, receipt: receipt, owner: owner)
    }

    func saveReceipt(_ receipt: AskExecutionReceipt, identity: AskExecutionIdentity, owner: String) async throws {
        try await store(owner).saveReceipt(receipt, identity: identity, owner: owner)
    }

    func recordExecution(id: String, event: AskExecutionAudit.Event, owner: String) async throws {
        try await store(owner).recordExecution(id: id, event: event, owner: owner)
    }

    func save(_ conversation: AskConversation, owner: String) async throws {
        try await store(owner).save(conversation, owner: owner)
    }

    func load(id: String, owner: String) async throws -> AskConversation? {
        try await store(owner).load(id: id, owner: owner)
    }

    func list(owner: String) async throws -> [AskConversationSummary] {
        try await store(owner).list(owner: owner)
    }

    func delete(id: String, owner: String) async throws {
        try await store(owner).delete(id: id, owner: owner)
    }

    func saveDraft(_ draft: AskDraft, key: String, owner: String) async throws {
        try await store(owner).saveDraft(draft, key: key, owner: owner)
    }

    func draft(key: String, owner: String) async throws -> AskDraft? {
        try await store(owner).draft(key: key, owner: owner)
    }

    func savedChatDrafts(owner: String) async throws -> [AskSavedChatDraft] {
        try await store(owner).savedChatDrafts(owner: owner)
    }

    func associateTool(id: String, conversationId: String, owner: String) async throws {
        try await store(owner).associateTool(id: id, conversationId: conversationId, owner: owner)
    }

    func claimTool(id: String, owner: String) async throws -> Bool {
        try await store(owner).claimTool(id: id, owner: owner)
    }

    func saveToolResult(_ result: AskToolResultRequest, owner: String) async throws {
        try await store(owner).saveToolResult(result, owner: owner)
    }

    func toolResult(id: String, owner: String) async throws -> AskToolResultRequest? {
        try await store(owner).toolResult(id: id, owner: owner)
    }
}

/// Keeps nothing; the fallback when no in-memory store could be opened, so a
/// temporary conversation is still never written to the persistent cache.
struct AskDiscardingCache: AskCaching {
    func execution(id _: String, owner _: String) async throws -> AskExecutionEntry? { nil }
    func executions(conversationId _: String, owner _: String) async throws -> [AskExecutionEntry] { [] }
    func claimExecution(_: AskExecutionAudit, owner _: String) async throws -> Bool { true }
    func saveRejectedToolReceipt(audit _: AskExecutionAudit, receipt _: AskToolResultRequest, owner _: String) async throws {}
    func saveReceipt(_: AskExecutionReceipt, identity _: AskExecutionIdentity, owner _: String) async throws {}
    func recordExecution(id _: String, event _: AskExecutionAudit.Event, owner _: String) async throws {}
    func save(_: AskConversation, owner _: String) async throws {}
    func load(id _: String, owner _: String) async throws -> AskConversation? { nil }
    func list(owner _: String) async throws -> [AskConversationSummary] { [] }
    func delete(id _: String, owner _: String) async throws {}
    func saveDraft(_: AskDraft, key _: String, owner _: String) async throws {}
    func draft(key _: String, owner _: String) async throws -> AskDraft? { nil }
    func savedChatDrafts(owner _: String) async throws -> [AskSavedChatDraft] { [] }
    func associateTool(id _: String, conversationId _: String, owner _: String) async throws {}
    func claimTool(id _: String, owner _: String) async throws -> Bool { true }
    func saveToolResult(_: AskToolResultRequest, owner _: String) async throws {}
    func toolResult(id _: String, owner _: String) async throws -> AskToolResultRequest? { nil }
}
