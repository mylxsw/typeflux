import Foundation

/// Keeps launcher construction independent of SQLite availability. Storage is
/// opened on demand off the main actor; failures stay explicit and no operation
/// is replayed. In particular, unavailable execution history never becomes an
/// empty in-memory journal that could authorize a duplicate tool invocation.
actor RecoveringAskConversationCache: AskCaching {
    private let factory: @Sendable () throws -> any AskCaching
    private let uptime: @Sendable () -> TimeInterval
    private var cache: (any AskCaching)?
    private var budget = ModuleRecoveryBudget()
    private var inFlight = 0
    private var failed = false

    init(
        factory: @escaping @Sendable () throws -> any AskCaching = {
            try AskConversationCache(url: AskConversationCache.defaultURL())
        },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.factory = factory
        self.uptime = uptime
    }

    private func perform<T>(_ body: (any AskCaching) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !failed || inFlight == 0, budget.permitsAttempt(at: uptime()) else { throw AskRecoveryError.storage }
        if cache == nil {
            do {
                cache = try factory()
                failed = false
            } catch {
                budget.failed(at: uptime())
                throw error
            }
        }
        guard let cache else { throw AskRecoveryError.storage }
        inFlight += 1
        defer {
            inFlight -= 1
            if failed, inFlight == 0 {
                self.cache = nil
            }
        }
        do {
            let result = try await body(cache)
            if !failed {
                budget.succeeded(at: uptime())
            }
            return result
        } catch {
            // Binding/approval errors and cancellation do not invalidate the DB.
            let isStorage = (error as NSError).domain == NSCocoaErrorDomain
                || (error as? AskRecoveryError) == .storage
            if isStorage, !failed {
                failed = true
                budget.failed(at: uptime())
            }
            throw error
        }
    }

    func execution(id: String, owner: String) async throws -> AskExecutionEntry? {
        try await perform { try await $0.execution(id: id, owner: owner) }
    }

    func executions(conversationId: String, owner: String) async throws -> [AskExecutionEntry] {
        try await perform { try await $0.executions(conversationId: conversationId, owner: owner) }
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
