import Foundation

/// Typed access to the one canonical engine. Presentation processes never open its store.
struct FeatureAskCache: AskCaching {
    let connection: FeatureRPC
    var generation: @Sendable () async -> Int = { await MainActor.run { AuthState.shared.sessionGeneration } }
    var synchronizeAuth: @Sendable (FeatureRPC, String) async -> Bool = { connection, owner in
        await FeatureAuth.synchronizeCacheRead(connection: connection, owner: owner)
    }

    func execution(id: String, owner: String) async throws -> AskExecutionEntry? { try await invoke("cache.execution.0", Call0(id: id, owner: owner)) }
    func executions(conversationId: String, owner: String) async throws -> [AskExecutionEntry] { try await invoke("cache.executions.1", Call1(conversationId: conversationId, owner: owner)) }
    func recoveryExecutions(conversationId: String, runId: String, owner: String) async throws -> [AskExecutionEntry] { try await invoke("cache.executions.1", Call1(conversationId: conversationId, owner: owner, runId: runId)) }
    func claimExecution(_ audit: AskExecutionAudit, owner: String) async throws -> Bool { try await invoke("cache.claimExecution.2", Call2(audit: audit, owner: owner)) }
    func saveRejectedToolReceipt(audit: AskExecutionAudit, receipt: AskToolResultRequest, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.saveRejectedToolReceipt.3", Call3(audit: audit, receipt: receipt, owner: owner)) }
    func saveReceipt(_ receipt: AskExecutionReceipt, identity: AskExecutionIdentity, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.saveReceipt.4", Call4(receipt: receipt, identity: identity, owner: owner)) }
    func recordExecution(id: String, event: AskExecutionAudit.Event, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.recordExecution.5", Call5(id: id, event: event, owner: owner)) }
    func save(_ conversation: AskConversation, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.save.6", Call6(conversation: conversation, owner: owner)) }
    func load(id: String, owner: String) async throws -> AskConversation? { try await invoke("cache.load.7", Call7(id: id, owner: owner)) }
    func list(owner: String) async throws -> [AskConversationSummary] { try await invoke("cache.list.8", Call8(owner: owner)) }
    func delete(id: String, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.delete.9", Call9(id: id, owner: owner)) }
    func saveDraft(_ draft: AskDraft, key: String, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.saveDraft.10", Call10(draft: draft, key: key, owner: owner)) }
    func draft(key: String, owner: String) async throws -> AskDraft? { try await invoke("cache.draft.11", Call11(key: key, owner: owner)) }
    func savedChatDrafts(owner: String) async throws -> [AskSavedChatDraft] { try await invoke("cache.savedChatDrafts.12", Call12(owner: owner)) }
    func associateTool(id: String, conversationId: String, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.associateTool.13", Call13(id: id, conversationId: conversationId, owner: owner)) }
    func claimTool(id: String, owner: String) async throws -> Bool { try await invoke("cache.claimTool.14", Call14(id: id, owner: owner)) }
    func saveToolResult(_ result: AskToolResultRequest, owner: String) async throws { let _: FeatureRPC.Empty = try await invoke("cache.saveToolResult.15", Call15(result: result, owner: owner)) }
    func toolResult(id: String, owner: String) async throws -> AskToolResultRequest? { try await invoke("cache.toolResult.16", Call16(id: id, owner: owner)) }

    private func invoke<Input: Encodable & Sendable, Output: Decodable & Sendable>(_ method: String, _ value: Input) async throws -> Output {
        do { return try await invokeAuthorized(method, value) }
        catch FeatureRPC.Failure.unavailable {
            // Reads have no side effects. Wait for the repaired channel and
            // retry once; writes and execution claims are never replayed here.
            guard Self.readMethods.contains(method) else { throw FeatureRPC.Failure.unavailable }
            try Task.checkCancellation()
            return try await invokeAuthorized(method, value)
        }
    }

    private func invokeAuthorized<Input: Encodable & Sendable, Output: Decodable & Sendable>(_ method: String, _ value: Input) async throws -> Output {
        do { return try await invokeOnce(method, value) }
        catch AuthError.unauthorized {
            // Only reads may be repeated. Keep the original owner binding even
            // if login state changes while refreshing the host snapshot.
            guard Self.readMethods.contains(method),
                  let identity = try? JSONDecoder().decode(CacheOwner.self, from: JSONEncoder().encode(value)),
                  await synchronizeAuth(connection, identity.owner) else { throw AuthError.unauthorized }
            return try await invokeOnce(method, value)
        }
    }

    private static let readMethods: Set<String> = ["cache.execution.0", "cache.executions.1", "cache.load.7",
        "cache.list.8", "cache.draft.11", "cache.savedChatDrafts.12", "cache.toolResult.16"]
    private struct CacheOwner: Decodable { let owner: String }

    private func invokeOnce<Input: Encodable & Sendable, Output: Decodable & Sendable>(_ method: String, _ value: Input) async throws -> Output {
        let generation = await generation()
        let call = FeatureAskCall(generation: generation, payload: try JSONEncoder().encode(value))
        let reply: FeatureAskReply
        // Draft writes and verification must leave time for the quit recovery
        // copy if the host channel or storage stops responding.
        let timeout: Duration = ["cache.saveDraft.10", "cache.draft.11"].contains(method) ? .seconds(15) : .seconds(120)
        do { reply = try await connection.call(method, call, timeout: timeout) }
        catch FeatureRPC.Failure.cancelled { throw CancellationError() }
        catch {
            AskFailureDiagnostics.shared.record(.cacheCall, error: error, method: method)
            throw error
        }
        if let error = reply.error {
            AskFailureDiagnostics.shared.record(.cacheCall, error: error.restored, method: method)
            throw error.restored
        }
        guard let payload = reply.payload else { throw FeatureRPC.Failure.invalidMessage }
        return try JSONDecoder().decode(Output.self, from: payload)
    }

    static func handle(_ method: String, payload: Data, api: any AskCaching) async throws -> Data {
        let reply: FeatureAskReply
        do {
            let result: Data
            switch method {
            case "cache.execution.0":
                let value = try JSONDecoder().decode(Call0.self, from: payload)
                result = try JSONEncoder().encode(try await api.execution(id: value.id, owner: value.owner))
            case "cache.executions.1":
                let value = try JSONDecoder().decode(Call1.self, from: payload)
                if let runId = value.runId {
                    result = try JSONEncoder().encode(try await api.recoveryExecutions(conversationId: value.conversationId, runId: runId, owner: value.owner))
                } else {
                    result = try JSONEncoder().encode(try await api.executions(conversationId: value.conversationId, owner: value.owner))
                }
            case "cache.claimExecution.2":
                let value = try JSONDecoder().decode(Call2.self, from: payload)
                result = try JSONEncoder().encode(try await api.claimExecution(value.audit, owner: value.owner))
            case "cache.saveRejectedToolReceipt.3":
                let value = try JSONDecoder().decode(Call3.self, from: payload)
                try await api.saveRejectedToolReceipt(audit: value.audit, receipt: value.receipt, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.saveReceipt.4":
                let value = try JSONDecoder().decode(Call4.self, from: payload)
                try await api.saveReceipt(value.receipt, identity: value.identity, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.recordExecution.5":
                let value = try JSONDecoder().decode(Call5.self, from: payload)
                try await api.recordExecution(id: value.id, event: value.event, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.save.6":
                let value = try JSONDecoder().decode(Call6.self, from: payload)
                try await api.save(value.conversation, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.load.7":
                let value = try JSONDecoder().decode(Call7.self, from: payload)
                result = try JSONEncoder().encode(try await api.load(id: value.id, owner: value.owner))
            case "cache.list.8":
                let value = try JSONDecoder().decode(Call8.self, from: payload)
                result = try JSONEncoder().encode(try await api.list(owner: value.owner))
            case "cache.delete.9":
                let value = try JSONDecoder().decode(Call9.self, from: payload)
                try await api.delete(id: value.id, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.saveDraft.10":
                let value = try JSONDecoder().decode(Call10.self, from: payload)
                try await api.saveDraft(value.draft, key: value.key, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.draft.11":
                let value = try JSONDecoder().decode(Call11.self, from: payload)
                result = try JSONEncoder().encode(try await api.draft(key: value.key, owner: value.owner))
            case "cache.savedChatDrafts.12":
                let value = try JSONDecoder().decode(Call12.self, from: payload)
                result = try JSONEncoder().encode(try await api.savedChatDrafts(owner: value.owner))
            case "cache.associateTool.13":
                let value = try JSONDecoder().decode(Call13.self, from: payload)
                try await api.associateTool(id: value.id, conversationId: value.conversationId, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.claimTool.14":
                let value = try JSONDecoder().decode(Call14.self, from: payload)
                result = try JSONEncoder().encode(try await api.claimTool(id: value.id, owner: value.owner))
            case "cache.saveToolResult.15":
                let value = try JSONDecoder().decode(Call15.self, from: payload)
                try await api.saveToolResult(value.result, owner: value.owner)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "cache.toolResult.16":
                let value = try JSONDecoder().decode(Call16.self, from: payload)
                result = try JSONEncoder().encode(try await api.toolResult(id: value.id, owner: value.owner))
            default: throw FeatureRPC.Failure.invalidMessage
            }
            reply = .init(payload: result, error: nil)
        } catch {
            AskFailureDiagnostics.shared.record(.cacheCall, error: error, method: method)
            reply = .init(payload: nil, error: .init(error))
        }
        return try JSONEncoder().encode(reply)
    }

    private struct Call0: Codable, Sendable {
        let id: String
        let owner: String
    }
    private struct Call1: Codable, Sendable {
        let conversationId: String
        let owner: String
        var runId: String? = nil
    }
    private struct Call2: Codable, Sendable {
        let audit: AskExecutionAudit
        let owner: String
    }
    private struct Call3: Codable, Sendable {
        let audit: AskExecutionAudit
        let receipt: AskToolResultRequest
        let owner: String
    }
    private struct Call4: Codable, Sendable {
        let receipt: AskExecutionReceipt
        let identity: AskExecutionIdentity
        let owner: String
    }
    private struct Call5: Codable, Sendable {
        let id: String
        let event: AskExecutionAudit.Event
        let owner: String
    }
    private struct Call6: Codable, Sendable {
        let conversation: AskConversation
        let owner: String
    }
    private struct Call7: Codable, Sendable {
        let id: String
        let owner: String
    }
    private struct Call8: Codable, Sendable {
        let owner: String
    }
    private struct Call9: Codable, Sendable {
        let id: String
        let owner: String
    }
    private struct Call10: Codable, Sendable {
        let draft: AskDraft
        let key: String
        let owner: String
    }
    private struct Call11: Codable, Sendable {
        let key: String
        let owner: String
    }
    private struct Call12: Codable, Sendable {
        let owner: String
    }
    private struct Call13: Codable, Sendable {
        let id: String
        let conversationId: String
        let owner: String
    }
    private struct Call14: Codable, Sendable {
        let id: String
        let owner: String
    }
    private struct Call15: Codable, Sendable {
        let result: AskToolResultRequest
        let owner: String
    }
    private struct Call16: Codable, Sendable {
        let id: String
        let owner: String
    }
}
