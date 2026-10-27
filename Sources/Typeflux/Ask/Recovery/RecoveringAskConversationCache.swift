import Foundation

/// Keeps launcher construction independent of SQLite availability. Storage is
/// opened on demand off the main actor; failures stay explicit and no operation
/// is replayed. In particular, unavailable execution history never becomes an
/// empty in-memory journal that could authorize a duplicate tool invocation.
actor RecoveringAskConversationCache: AskCaching {
    nonisolated let module: ModuleHandle<any AskCaching>

    init(
        factory: @escaping @Sendable () throws -> any AskCaching = {
            try AskConversationCache(url: AskConversationCache.defaultURL())
        },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        policy: ModulePolicy = .init(), healthStore: ModuleHealthStore? = nil
    ) {
        module = ModuleHandle(policy: policy, healthStore: healthStore, factory: { try factory() }, classify: { error in
            // Binding/approval errors do not invalidate the durable journal.
            let storage = (error as NSError).domain == NSCocoaErrorDomain
                || (error as? AskRecoveryError) == .storage
            return storage ? .recover : .operationOnly
        }, uptime: uptime)
    }

    private func perform<T: Sendable>(
        _ body: @escaping @Sendable (any AskCaching) async throws -> T
    ) async throws -> T {
        do { return try await module.perform(body) } catch let error as ModuleFailure {
            AskFailureDiagnostics.shared.record(.cacheModule, error: error)
            // Preserve the existing fail-closed recovery contract for approvals
            // and execution claims. An unavailable journal is never empty.
            throw AskRecoveryError.storage
        }
    }

    nonisolated func preventNewWork() { module.preventNewWork() }
    func shutdown() async { await module.shutdown() }

    func execution(id: String, owner: String) async throws -> AskExecutionEntry? {
        try await perform { try await $0.execution(id: id, owner: owner) }
    }

    func executions(conversationId: String, owner: String) async throws -> [AskExecutionEntry] {
        try await perform { try await $0.executions(conversationId: conversationId, owner: owner) }
    }

    func recoveryExecutions(conversationId: String, runId: String, owner: String) async throws -> [AskExecutionEntry] {
        try await perform { try await $0.recoveryExecutions(conversationId: conversationId, runId: runId, owner: owner) }
    }

    func claimExecution(_ audit: AskExecutionAudit, owner: String) async throws -> Bool {
        try await perform { try await $0.claimExecution(audit, owner: owner) }
    }

    func saveRejectedToolReceipt(audit: AskExecutionAudit, receipt: AskToolResultRequest, owner: String) async throws {
        try await perform { try await $0.saveRejectedToolReceipt(audit: audit, receipt: receipt, owner: owner) }
    }

    func saveReceipt(_ receipt: AskExecutionReceipt, identity: AskExecutionIdentity, owner: String) async throws {
        try await perform { try await $0.saveReceipt(receipt, identity: identity, owner: owner) }
    }

    func recordExecution(id: String, event: AskExecutionAudit.Event, owner: String) async throws {
        try await perform { try await $0.recordExecution(id: id, event: event, owner: owner) }
    }

    func save(_ conversation: AskConversation, owner: String) async throws {
        try await perform { try await $0.save(conversation, owner: owner) }
    }

    func load(id: String, owner: String) async throws -> AskConversation? {
        try await perform { try await $0.load(id: id, owner: owner) }
    }

    func list(owner: String) async throws -> [AskConversationSummary] {
        try await perform { try await $0.list(owner: owner) }
    }

    func delete(id: String, owner: String) async throws {
        try await perform { try await $0.delete(id: id, owner: owner) }
    }

    func saveDraft(_ draft: AskDraft, key: String, owner: String) async throws {
        try await perform { try await $0.saveDraft(draft, key: key, owner: owner) }
    }

    func draft(key: String, owner: String) async throws -> AskDraft? {
        try await perform { try await $0.draft(key: key, owner: owner) }
    }

    func savedChatDrafts(owner: String) async throws -> [AskSavedChatDraft] {
        try await perform { try await $0.savedChatDrafts(owner: owner) }
    }

    func associateTool(id: String, conversationId: String, owner: String) async throws {
        try await perform { try await $0.associateTool(id: id, conversationId: conversationId, owner: owner) }
    }

    func claimTool(id: String, owner: String) async throws -> Bool {
        try await perform { try await $0.claimTool(id: id, owner: owner) }
    }

    func saveToolResult(_ result: AskToolResultRequest, owner: String) async throws {
        try await perform { try await $0.saveToolResult(result, owner: owner) }
    }

    func toolResult(id: String, owner: String) async throws -> AskToolResultRequest? {
        try await perform { try await $0.toolResult(id: id, owner: owner) }
    }
}
