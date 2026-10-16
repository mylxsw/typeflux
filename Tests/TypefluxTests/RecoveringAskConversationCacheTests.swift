import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Recoverable conversation storage")
struct RecoveringAskConversationCacheTests {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var time: TimeInterval = 0
        var attempts = 0
        func now() -> TimeInterval {
            lock.withLock { time }
        }

        func advance() {
            lock.withLock { time += 301 }
        }

        func attempt() -> Int {
            lock.withLock { attempts += 1; return attempts }
        }

        var count: Int {
            lock.withLock { attempts }
        }
    }

    @Test func `construction does not open storage and failure does not pretend history is empty`() async throws {
        let state = State()
        let cache = RecoveringAskConversationCache(factory: {
            if state.attempt() == 1 {
                throw CocoaError(.fileReadNoPermission)
            }
            return try AskConversationCache.inMemory()
        }, uptime: { state.now() })
        #expect(state.count == 0)
        await #expect(throws: CocoaError.self) { _ = try await cache.list(owner: "owner") }
        #expect(state.count == 1)
        await #expect(throws: AskRecoveryError.self) { _ = try await cache.claimTool(id: "tool", owner: "owner") }
        #expect(state.count == 1)
        state.advance()
        #expect(try await cache.list(owner: "owner").isEmpty)
        #expect(state.count == 2)
        #expect(try await cache.claimTool(id: "tool", owner: "owner"))
        #expect(try await !cache.claimTool(id: "tool", owner: "owner"))
        await cache.shutdown()
    }

    @Test func `failed write is not replayed and recovery preserves durable claims`() async throws {
        let state = State()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        let cache = RecoveringAskConversationCache(factory: {
            _ = state.attempt()
            return try AskConversationCache(url: url)
        }, uptime: { state.now() })
        #expect(try await cache.claimTool(id: "once", owner: "owner"))
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(
            database,
            "CREATE TRIGGER fail_save BEFORE INSERT ON ask_drafts BEGIN SELECT RAISE(ABORT,'fixture'); END;",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        await #expect(throws: (any Error).self) {
            try await cache.saveDraft(.init(text: "unsaved"), key: "draft", owner: "owner")
        }
        #expect(state.count == 1)
        #expect(sqlite3_exec(database, "DROP TRIGGER fail_save;", nil, nil, nil) == SQLITE_OK)
        for _ in 0..<200 where await cache.module.supervisor.health().hasLifecycleWork {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.advance()
        #expect(try await cache.draft(key: "draft", owner: "owner") == nil)
        #expect(try await !cache.claimTool(id: "once", owner: "owner"))
        #expect(state.count == 2)
        try await cache.saveDraft(.init(text: "explicit save"), key: "draft", owner: "owner")
        #expect(try await cache.draft(key: "draft", owner: "owner")?.text == "explicit save")
        await cache.shutdown()
    }

    @Test func `forwarding preserves account scoping and execution receipts`() async throws {
        let state = State()
        let cache = RecoveringAskConversationCache(factory: {
            _ = state.attempt()
            return try AskConversationCache.inMemory()
        })
        let value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        let receipt = AskRecoveryFixture.receipt(value)
        try await cache.save(value, owner: "owner")
        #expect(try await cache.load(id: value.id, owner: "owner")?.id == value.id)
        #expect(try await cache.load(id: value.id, owner: "other") == nil)
        #expect(try await cache.list(owner: "owner").count == 1)
        #expect(try await cache.claimExecution(audit, owner: "owner"))
        try await cache.saveReceipt(receipt, identity: audit.identity, owner: "owner")
        #expect(try await cache.execution(id: audit.identity.key, owner: "owner")?.receipt == receipt)
        #expect(try await cache.executions(conversationId: value.id, owner: "owner").count == 1)
        try await cache.recordExecution(id: audit.identity.key, event: .acknowledged, owner: "owner")
        await #expect(throws: AskRecoveryError.self) {
            try await cache.saveReceipt(receipt, identity: audit.identity, owner: "wrong-owner")
        }
        #expect(state.count == 1, "A binding error must not discard the live connection")
        let invalidReceipt = AskToolResultRequest(
            runId: "run",
            deviceId: "device",
            toolCallId: "call",
            content: "invalid",
            isError: false
        )
        await #expect(throws: AskRecoveryError.self) {
            try await cache.saveRejectedToolReceipt(audit: audit, receipt: invalidReceipt, owner: "owner")
        }
        try await cache.associateTool(id: "other-tool", conversationId: value.id, owner: "owner")
        let result = AskToolResultRequest(
            runId: "run",
            deviceId: "device",
            toolCallId: "other-tool",
            content: "done",
            isError: false
        )
        try await cache.saveToolResult(result, owner: "owner")
        #expect(try await cache.toolResult(id: "run/other-tool", owner: "owner") == result)
        #expect(try await cache.savedChatDrafts(owner: "owner").isEmpty)
        try await cache.delete(id: value.id, owner: "owner")
        #expect(try await cache.load(id: value.id, owner: "owner") == nil)
        await cache.shutdown()
    }

    @Test func `cancelled request does not open storage`() async throws {
        let state = State()
        let cache = RecoveringAskConversationCache(factory: {
            _ = state.attempt()
            return try AskConversationCache.inMemory()
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.list(owner: "owner")
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(state.count == 0)
        await cache.shutdown()
    }
    @Test func `blocked synchronous database open cannot block supervision or create replacement writers`() async throws {
        let state = State()
        let release = DispatchSemaphore(value: 0)
        var policy = ModulePolicy(); policy.startupTimeout = 0.03
        let cache = RecoveringAskConversationCache(factory: {
            _ = state.attempt()
            _ = release.wait(timeout: .now() + 3)
            return try AskConversationCache.inMemory()
        }, uptime: { state.now() }, policy: policy)
        await #expect(throws: AskRecoveryError.storage) { _ = try await cache.list(owner: "owner") }
        #expect(state.count == 1)
        #expect(await cache.module.supervisor.health().failure == .startupTimeout)
        state.advance()
        await #expect(throws: AskRecoveryError.storage) { _ = try await cache.claimTool(id: "once", owner: "owner") }
        #expect(state.count == 1)
        cache.preventNewWork()
        await cache.shutdown()
        release.signal()
        for _ in 0..<200 where await cache.module.supervisor.health().hasLifecycleWork {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await cache.module.setEnabled(true)
        await #expect(throws: AskRecoveryError.storage) { _ = try await cache.list(owner: "owner") }
        #expect(state.count == 1)
    }

    @Test func `committed execution claim survives a timed out response and is never claimed twice`() async throws {
        let state = State(), release = DispatchSemaphore(value: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        var policy = ModulePolicy(); policy.operationTimeout = 0.05; policy.automaticallyRecover = false
        let cache = RecoveringAskConversationCache(factory: {
            _ = state.attempt()
            return try AskConversationCache(url: url)
        }, uptime: { state.now() }, policy: policy)
        let claim = Task {
            try await cache.module.perform { underlying in
                let claimed = try await underlying.claimTool(id: "effect-may-have-happened", owner: "owner")
                _ = release.wait(timeout: .now() + 3)
                return claimed
            }
        }
        await #expect(throws: ModuleFailure.operationTimeout) { try await claim.value }
        #expect(await cache.module.supervisor.health().activeOperations == 1)
        release.signal()
        for _ in 0..<200 {
            let health = await cache.module.supervisor.health()
            if !health.hasLifecycleWork, health.activeOperations == 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.advance()
        #expect(try await !cache.claimTool(id: "effect-may-have-happened", owner: "owner"))
        #expect(state.count == 2)
        await cache.shutdown()
    }

}
