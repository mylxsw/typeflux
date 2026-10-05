import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Rejected tool receipts")
struct AskRejectedReceiptTests {
    func audit() -> AskExecutionAudit {
        var audit = AskRecoveryFixture.audit(AskRecoveryFixture.conversation())
        audit.approvalId = nil
        audit.approvedAt = nil
        audit.toolVersion = "preparation-refusal-v1"
        return audit
    }

    func receipt(_ audit: AskExecutionAudit) -> AskToolResultRequest {
        .init(runId: audit.identity.runId, deviceId: audit.identity.deviceId, toolCallId: audit.identity.callId,
              content: "The action was not executed.", isError: true,
              harness: .init(version: 1, outcome: .init(status: "denied", eventDispatched: false)))
    }

    @Test(arguments: ["INSERT ON ask_tool_owners", "INSERT ON ask_execution", "UPDATE ON ask_tools"])
    func `storage failures roll back the entire refusal`(_ boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite"), cache = try AskConversationCache(url: url)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let audit = audit()
        #expect(sqlite3_exec(
            db,
            "CREATE TRIGGER fail_refusal BEFORE \(boundary) BEGIN SELECT RAISE(ABORT,'fixture'); END;",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        await #expect(throws: (any Error).self) {
            try await cache.saveRejectedToolReceipt(audit: audit, receipt: receipt(audit), owner: "owner")
        }
        let reopened = try AskConversationCache(url: url)
        #expect(try await reopened.execution(id: audit.identity.key, owner: "owner") == nil)
        #expect(try await reopened.executions(conversationId: audit.identity.conversationId, owner: "owner").isEmpty)
        #expect(sqlite3_exec(db, "DROP TRIGGER fail_refusal", nil, nil, nil) == SQLITE_OK)
        try await reopened.saveRejectedToolReceipt(audit: audit, receipt: receipt(audit), owner: "owner")
        let entry = try #require(await cache.execution(id: audit.identity.key, owner: "owner"))
        #expect(!entry.unknown && entry.receipt == .tool(receipt(audit)))
    }

    @Test func `duplicate refusal is immutable across connections`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        let first = try AskConversationCache(url: url), second = try AskConversationCache(url: url)
        let audit = audit(), result = receipt(audit)
        async let a: Void = first.saveRejectedToolReceipt(audit: audit, receipt: result, owner: "owner")
        async let b: Void = second.saveRejectedToolReceipt(audit: audit, receipt: result, owner: "owner")
        _ = try await (a, b)
        try await first.recordExecution(id: audit.identity.key, event: .acknowledged, owner: "owner")
        let before = try await first.execution(id: audit.identity.key, owner: "owner")
        try await second.saveRejectedToolReceipt(audit: audit, receipt: result, owner: "owner")
        #expect(try await first.execution(id: audit.identity.key, owner: "owner") == before)
        var changed = result; changed.content = "Changed"
        await #expect(throws: AskRecoveryError.self) {
            try await second.saveRejectedToolReceipt(audit: audit, receipt: changed, owner: "owner")
        }
        #expect(try await first.execution(id: audit.identity.key, owner: "owner") == before)
    }

    @Test(arguments: [true, false])
    func `existing claims are never reclassified as unexecuted`(_ legacy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        let audit = audit()
        if legacy {
            _ = try await cache.claimTool(id: audit.identity.key, owner: "owner")
        } else {
            _ = try await cache.claimExecution(audit, owner: "owner")
        }
        let before = try await cache.execution(id: audit.identity.key, owner: "owner")
        await #expect(throws: AskRecoveryError.self) {
            try await cache.saveRejectedToolReceipt(audit: audit, receipt: receipt(audit), owner: "owner")
        }
        #expect(try await cache.execution(id: audit.identity.key, owner: "owner") == before)
    }

    @Test(arguments: [
        "identity",
        "kind",
        "call",
        "approval",
        "approved-at",
        "success",
        "version",
        "dispatched",
        "unknown",
        "deleted"
    ])
    func `invalid refusal cannot create A receipt`(_ violation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        var audit = audit(), result = receipt(audit)
        switch violation {
        case "identity": audit.identity.deviceId = ""
        case "kind": audit.identity.kind = "model"
        case "call": result.toolCallId = "other"
        case "approval": audit.approvalId = "grant"
        case "approved-at": audit.approvedAt = Date()
        case "success": result.isError = false
        case "version": result.harness?.version = 9
        case "dispatched": result.harness?.outcome?.eventDispatched = true
        case "unknown": result.harness?.outcome?.status = "unknown"
        default: try await cache.delete(id: audit.identity.conversationId, owner: "owner")
        }
        await #expect(throws: AskRecoveryError.self) {
            try await cache.saveRejectedToolReceipt(audit: audit, receipt: result, owner: "owner")
        }
        #expect(try await cache.execution(id: audit.identity.key, owner: "owner") == nil)
    }
}
