import Foundation
import SQLite3

extension AskConversationCache {
    func execution(id: String, owner: String) throws -> AskExecutionEntry? {
        let statement = try prepare("SELECT data FROM ask_tools WHERE owner=? AND id=?", strings: [owner, id])
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: break
        default: throw AskRecoveryError.storage
        }
        let audit = try read(table: "ask_execution", id: id, owner: owner)
            .map { try AskCoding.decoder().decode(AskExecutionAudit.self, from: $0) }
        var receipt: AskExecutionReceipt?
        if let bytes = blob(statement) {
            receipt = try audit?.identity.kind == "model"
                ? .inference(AskCoding.decoder().decode(AskInferenceResult.self, from: bytes))
                : .tool(AskCoding.decoder().decode(AskToolResultRequest.self, from: bytes))
        }
        let deleted = try audit
            .map { try read(table: "ask_deleted", id: $0.identity.conversationId, owner: owner) != nil } ?? false
        return .init(id: id, audit: audit, receipt: receipt, deleted: deleted)
    }

    func executions(conversationId: String, owner: String) throws -> [AskExecutionEntry] {
        let statement = try prepare(
            "SELECT id FROM ask_tool_owners WHERE owner=? AND conversation_id IN (?,?) ORDER BY id",
            strings: [owner, AskConversationID.canonical(conversationId), AskConversationID.legacy(conversationId)]
        )
        defer { sqlite3_finalize(statement) }
        var entries: [AskExecutionEntry] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 0),
               let entry = try execution(id: String(cString: pointer), owner: owner) {
                entries.append(entry)
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw AskRecoveryError.storage }
        return entries
    }

    /// Claim, binding and approval audit must all reach disk before dispatch.
    func claimExecution(_ audit: AskExecutionAudit, owner: String) throws -> Bool {
        let identity = audit.identity
        guard ![identity.owner, identity.conversationId, identity.runId, identity.deviceId,
                identity.callId, identity.stepId, audit.toolVersion, audit.argumentsHash].contains(where: \.isEmpty),
            ["model", "tool"].contains(identity.kind),
            try read(table: "ask_deleted", id: identity.conversationId, owner: owner) == nil
        else { throw AskRecoveryError.binding }
        try execute("BEGIN IMMEDIATE", strings: [])
        do {
            let claimed = try claimTool(id: identity.key, owner: owner)
            if claimed {
                try associateTool(id: identity.key, conversationId: identity.conversationId, owner: owner)
                try write(
                    table: "ask_execution",
                    id: identity.key,
                    owner: owner,
                    data: AskCoding.encoder().encode(audit)
                )
            }
            try execute("COMMIT", strings: [])
            return claimed
        } catch { try? execute("ROLLBACK", strings: []); throw error }
    }

    /// A receipt is immutable. Retransmission sends exactly these saved bytes.
    func saveReceipt(_ receipt: AskExecutionReceipt, identity: AskExecutionIdentity, owner: String) throws {
        try execute("BEGIN IMMEDIATE", strings: [])
        do {
            guard let entry = try execution(id: identity.key, owner: owner),
                  var audit = entry.audit, audit.identity == identity, receipt.matches(identity)
            else { throw AskRecoveryError.binding }
            if let previous = entry.receipt {
                // Dates in legacy harness receipts use second precision on disk.
                guard try receiptBytes(previous) == receiptBytes(receipt) else { throw AskRecoveryError.binding }
            } else {
                try write(table: "ask_tools", id: identity.key, owner: owner, data: receiptBytes(receipt))
                audit.record(.receiptSaved)
                try write(
                    table: "ask_execution",
                    id: identity.key,
                    owner: owner,
                    data: AskCoding.encoder().encode(audit)
                )
            }
            try execute("COMMIT", strings: [])
        } catch { try? execute("ROLLBACK", strings: []); throw error }
    }

    private func receiptBytes(_ receipt: AskExecutionReceipt) throws -> Data {
        let encoder = AskCoding.encoder(); encoder.outputFormatting = [.sortedKeys]
        switch receipt {
        case let .tool(value): return try encoder.encode(value)
        case let .inference(value): return try encoder.encode(value)
        }
    }

    func recordExecution(id: String, event: AskExecutionAudit.Event, owner: String) throws {
        try execute("BEGIN IMMEDIATE", strings: [])
        do {
            guard let entry = try execution(id: id, owner: owner), var audit = entry.audit,
                  ![.retransmitting, .acknowledged].contains(event) || entry.receipt != nil else {
                throw AskRecoveryError.binding
            }
            audit.record(event)
            try write(table: "ask_execution", id: id, owner: owner, data: AskCoding.encoder().encode(audit))
            try execute("COMMIT", strings: [])
        } catch { try? execute("ROLLBACK", strings: []); throw error }
    }
}
