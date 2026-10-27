import Foundation
import SQLite3
import Testing
@testable import Typeflux

struct AskRecoveryJournalScopeTests {
    @Test func failedStorageReadDoesNotOfferContinueOrReportIdleWorkAsRunning() {
        let run = AskRecoveryFixture.conversation().run
        let entry = AskExecutionEntry(id: "unavailable", audit: nil, receipt: nil)
        let recovery = AskRecoveryPresentation(run: run, entries: [entry], deviceId: "device", local: true)
        #expect(!recovery.canContinue && !recovery.unknown)
        #expect(AskRunPhase.resolve(run: run, busy: false, pendingApproval: false, recovery: recovery,
                                   storageUnavailable: true) == .needsDecision(step: 1))
        // A driver that is still unwinding retains its Stop control.
        #expect(AskRunPhase.resolve(run: run, busy: true, pendingApproval: false, recovery: recovery,
                                   storageUnavailable: true)?.offersStop == true)
    }

    @Test func currentRunIncludesToolModelAndUnauditedClaimsWithoutReadingOldReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let cache = try AskConversationCache(url: url)
        let value = AskRecoveryFixture.conversation()
        for model in [false, true] {
            let current = AskRecoveryFixture.conversation(model: model)
            let audit = AskRecoveryFixture.audit(current, model: model)
            #expect(try await cache.claimExecution(audit, owner: "owner"))
            try await cache.saveReceipt(AskRecoveryFixture.receipt(current, model: model), identity: audit.identity, owner: "owner")
        }
        var older = value
        older.run?.id = "older"
        let oldAudit = AskRecoveryFixture.audit(older)
        #expect(try await cache.claimExecution(oldAudit, owner: "owner"))
        #expect(try await cache.claimTool(id: "legacy", owner: "owner"))
        try await cache.associateTool(id: "legacy", conversationId: value.id, owner: "owner")
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        // A damaged historical receipt must not break an unrelated current run.
        #expect(sqlite3_exec(database, "UPDATE ask_tools SET data='not-json' WHERE id='older/call'", nil, nil, nil) == SQLITE_OK)
        let entries = try await cache.recoveryExecutions(conversationId: value.id, runId: "run", owner: "owner")
        #expect(Set(entries.map(\.id)) == ["run/call", "inference/run/call", "legacy"])
        #expect(entries.first { $0.id == "legacy" }?.unknown == true)
        #expect(entries.filter { $0.audit != nil }.allSatisfy { $0.receipt != nil })
        #expect(try await cache.recoveryExecutions(conversationId: value.id, runId: "run", owner: "other").isEmpty)
        #expect(try await cache.recoveryExecutions(conversationId: "other", runId: "run", owner: "owner").isEmpty)
        // Full history still reports corruption instead of silently losing evidence.
        await #expect(throws: (any Error).self) { _ = try await cache.executions(conversationId: value.id, owner: "owner") }
        try await cache.delete(id: value.id, owner: "owner")
        #expect(try await cache.recoveryExecutions(conversationId: value.id, runId: "run", owner: "owner").allSatisfy(\.deleted))
    }

    @Test func cancelledJournalReadCannotKeepTheStorageQueueOccupied() async throws {
        let cache = try AskConversationCache.inMemory()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.recoveryExecutions(conversationId: "conversation", runId: "run", owner: "owner")
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await cache.claimTool(id: "next", owner: "owner"))
    }
}
