import Foundation

/// Typed access to the one canonical engine. Presentation processes never open its store.
struct FeatureAskAPI: AskAPI {
    let connection: FeatureRPC
    var generation: @Sendable () async -> Int = { await MainActor.run { AuthState.shared.sessionGeneration } }

    func recover(conversationId: String, request: AskRecoveryRequest, token: String) async throws -> AskConversation { try await invoke("ask.recover.0", Call0(conversationId: conversationId, request: request, token: token)) }
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation { try await invoke("ask.cancel.1", Call1(conversationId: conversationId, runId: runId, partial: partial, token: token)) }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation { try await invoke("ask.inferenceResult.2", Call2(conversationId: conversationId, request: request, token: token)) }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation { try await invoke("ask.send.3", Call3(conversationId: conversationId, request: request, token: token)) }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation { try await invoke("ask.result.4", Call4(conversationId: conversationId, request: request, token: token)) }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation { try await invoke("ask.cancel.5", Call5(conversationId: conversationId, runId: runId, token: token)) }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation { try await invoke("ask.retry.6", Call6(conversationId: conversationId, runId: runId, deviceId: deviceId, modelRef: modelRef, token: token)) }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, maxSteps: Int?, token: String) async throws -> AskConversation { try await invoke("ask.retry.7", Call7(conversationId: conversationId, runId: runId, deviceId: deviceId, modelRef: modelRef, maxSteps: maxSteps, token: token)) }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation { try await invoke("ask.regenerate.8", Call8(conversationId: conversationId, request: request, token: token)) }
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation { try await invoke("ask.steer.9", Call9(conversationId: conversationId, request: request, token: token)) }
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation { try await invoke("ask.resume.10", Call10(conversationId: conversationId, runId: runId, token: token)) }
    func historySyncPending(token: String) async -> Bool { (try? await invoke("ask.historySyncPending.11", Call11(token: token))) ?? false }
    func updateTitle(id: String, request: AskTitleRequest, token: String) async throws -> AskConversation { try await invoke("ask.updateTitle.12", Call12(id: id, request: request, token: token)) }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] { try await invoke("ask.list.13", Call13(token: token, offset: offset)) }
    func conversation(id: String, token: String) async throws -> AskConversation { try await invoke("ask.conversation.14", Call14(id: id, token: token)) }
    func delete(conversationId: String, token: String) async throws { let _: FeatureRPC.Empty = try await invoke("ask.delete.15", Call15(conversationId: conversationId, token: token)) }
    func keep(conversationId: String, token: String) async throws -> AskConversation { try await invoke("ask.keep.16", Call16(conversationId: conversationId, token: token)) }
    func purgeMemory(token: String) async throws { let _: FeatureRPC.Empty = try await invoke("ask.purgeMemory.17", Call17(token: token)) }
    func purgeMemory(owner: String, token: String) async throws { let _: FeatureRPC.Empty = try await invoke("ask.purgeMemory.18", Call18(owner: owner, token: token)) }
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]? { try await invoke("ask.featureModels.19", Call19(feature: feature, token: token)) }
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage { try await invoke("ask.usage.20", Call20(id: id, runId: runId, cursor: cursor, token: token)) }
    func models(token: String) async throws -> [AskCloudModel] { try await invoke("ask.models.21", Call21(token: token)) }
    func models(token: String, scenario: String) async throws -> [AskCloudModel] { try await invoke("ask.models.22", Call22(token: token, scenario: scenario)) }

    private func invoke<Input: Encodable & Sendable, Output: Decodable & Sendable>(_ method: String, _ value: Input) async throws -> Output {
        let generation = await generation()
        let call = FeatureAskCall(generation: generation, payload: try JSONEncoder().encode(value))
        let reply: FeatureAskReply
        do { reply = try await connection.call(method, call, timeout: .seconds(120)) }
        catch FeatureRPC.Failure.cancelled { throw CancellationError() }
        if let error = reply.error { throw error.restored }
        guard let payload = reply.payload else { throw FeatureRPC.Failure.invalidMessage }
        return try JSONDecoder().decode(Output.self, from: payload)
    }

    static func handle(_ method: String, payload: Data, api: any AskAPI) async throws -> Data {
        let reply: FeatureAskReply
        do {
            let result: Data
            switch method {
            case "ask.recover.0":
                let value = try JSONDecoder().decode(Call0.self, from: payload)
                result = try JSONEncoder().encode(try await api.recover(conversationId: value.conversationId, request: value.request, token: value.token))
            case "ask.cancel.1":
                let value = try JSONDecoder().decode(Call1.self, from: payload)
                result = try JSONEncoder().encode(try await api.cancel(conversationId: value.conversationId, runId: value.runId, partial: value.partial, token: value.token))
            case "ask.inferenceResult.2":
                let value = try JSONDecoder().decode(Call2.self, from: payload)
                result = try JSONEncoder().encode(try await api.inferenceResult(conversationId: value.conversationId, request: value.request, token: value.token))
            case "ask.send.3":
                let value = try JSONDecoder().decode(Call3.self, from: payload)
                result = try JSONEncoder().encode(try await api.send(conversationId: value.conversationId, request: value.request, token: value.token))
            case "ask.result.4":
                let value = try JSONDecoder().decode(Call4.self, from: payload)
                result = try JSONEncoder().encode(try await api.result(conversationId: value.conversationId, request: value.request, token: value.token))
            case "ask.cancel.5":
                let value = try JSONDecoder().decode(Call5.self, from: payload)
                result = try JSONEncoder().encode(try await api.cancel(conversationId: value.conversationId, runId: value.runId, token: value.token))
            case "ask.retry.6":
                let value = try JSONDecoder().decode(Call6.self, from: payload)
                result = try JSONEncoder().encode(try await api.retry(conversationId: value.conversationId, runId: value.runId, deviceId: value.deviceId, modelRef: value.modelRef, token: value.token))
            case "ask.retry.7":
                let value = try JSONDecoder().decode(Call7.self, from: payload)
                result = try JSONEncoder().encode(try await api.retry(conversationId: value.conversationId, runId: value.runId, deviceId: value.deviceId, modelRef: value.modelRef, maxSteps: value.maxSteps, token: value.token))
            case "ask.regenerate.8":
                let value = try JSONDecoder().decode(Call8.self, from: payload)
                result = try JSONEncoder().encode(try await api.regenerate(conversationId: value.conversationId, request: value.request, token: value.token))
            case "ask.steer.9":
                let value = try JSONDecoder().decode(Call9.self, from: payload)
                result = try JSONEncoder().encode(try await api.steer(conversationId: value.conversationId, request: value.request, token: value.token))
            case "ask.resume.10":
                let value = try JSONDecoder().decode(Call10.self, from: payload)
                result = try JSONEncoder().encode(try await api.resume(conversationId: value.conversationId, runId: value.runId, token: value.token))
            case "ask.historySyncPending.11":
                let value = try JSONDecoder().decode(Call11.self, from: payload)
                result = try JSONEncoder().encode(await api.historySyncPending(token: value.token))
            case "ask.updateTitle.12":
                let value = try JSONDecoder().decode(Call12.self, from: payload)
                result = try JSONEncoder().encode(try await api.updateTitle(id: value.id, request: value.request, token: value.token))
            case "ask.list.13":
                let value = try JSONDecoder().decode(Call13.self, from: payload)
                result = try JSONEncoder().encode(try await api.list(token: value.token, offset: value.offset))
            case "ask.conversation.14":
                let value = try JSONDecoder().decode(Call14.self, from: payload)
                result = try JSONEncoder().encode(try await api.conversation(id: value.id, token: value.token))
            case "ask.delete.15":
                let value = try JSONDecoder().decode(Call15.self, from: payload)
                try await api.delete(conversationId: value.conversationId, token: value.token)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "ask.keep.16":
                let value = try JSONDecoder().decode(Call16.self, from: payload)
                result = try JSONEncoder().encode(try await api.keep(conversationId: value.conversationId, token: value.token))
            case "ask.purgeMemory.17":
                let value = try JSONDecoder().decode(Call17.self, from: payload)
                try await api.purgeMemory(token: value.token)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "ask.purgeMemory.18":
                let value = try JSONDecoder().decode(Call18.self, from: payload)
                try await api.purgeMemory(owner: value.owner, token: value.token)
                result = try JSONEncoder().encode(FeatureRPC.Empty())
            case "ask.featureModels.19":
                let value = try JSONDecoder().decode(Call19.self, from: payload)
                result = try JSONEncoder().encode(try await api.featureModels(feature: value.feature, token: value.token))
            case "ask.usage.20":
                let value = try JSONDecoder().decode(Call20.self, from: payload)
                result = try JSONEncoder().encode(try await api.usage(id: value.id, runId: value.runId, cursor: value.cursor, token: value.token))
            case "ask.models.21":
                let value = try JSONDecoder().decode(Call21.self, from: payload)
                result = try JSONEncoder().encode(try await api.models(token: value.token))
            case "ask.models.22":
                let value = try JSONDecoder().decode(Call22.self, from: payload)
                result = try JSONEncoder().encode(try await api.models(token: value.token, scenario: value.scenario))
            default: throw FeatureRPC.Failure.invalidMessage
            }
            reply = .init(payload: result, error: nil)
        } catch { reply = .init(payload: nil, error: .init(error)) }
        return try JSONEncoder().encode(reply)
    }

    private struct Call0: Codable, Sendable {
        let conversationId: String
        let request: AskRecoveryRequest
        let token: String
    }
    private struct Call1: Codable, Sendable {
        let conversationId: String
        let runId: String
        let partial: AskInferenceResult?
        let token: String
    }
    private struct Call2: Codable, Sendable {
        let conversationId: String
        let request: AskInferenceResult
        let token: String
    }
    private struct Call3: Codable, Sendable {
        let conversationId: String
        let request: AskSendRequest
        let token: String
    }
    private struct Call4: Codable, Sendable {
        let conversationId: String
        let request: AskToolResultRequest
        let token: String
    }
    private struct Call5: Codable, Sendable {
        let conversationId: String
        let runId: String
        let token: String
    }
    private struct Call6: Codable, Sendable {
        let conversationId: String
        let runId: String
        let deviceId: String
        let modelRef: String?
        let token: String
    }
    private struct Call7: Codable, Sendable {
        let conversationId: String
        let runId: String
        let deviceId: String
        let modelRef: String?
        let maxSteps: Int?
        let token: String
    }
    private struct Call8: Codable, Sendable {
        let conversationId: String
        let request: AskRegenerateRequest
        let token: String
    }
    private struct Call9: Codable, Sendable {
        let conversationId: String
        let request: AskSteerRequest
        let token: String
    }
    private struct Call10: Codable, Sendable {
        let conversationId: String
        let runId: String
        let token: String
    }
    private struct Call11: Codable, Sendable {
        let token: String
    }
    private struct Call12: Codable, Sendable {
        let id: String
        let request: AskTitleRequest
        let token: String
    }
    private struct Call13: Codable, Sendable {
        let token: String
        let offset: Int
    }
    private struct Call14: Codable, Sendable {
        let id: String
        let token: String
    }
    private struct Call15: Codable, Sendable {
        let conversationId: String
        let token: String
    }
    private struct Call16: Codable, Sendable {
        let conversationId: String
        let token: String
    }
    private struct Call17: Codable, Sendable {
        let token: String
    }
    private struct Call18: Codable, Sendable {
        let owner: String
        let token: String
    }
    private struct Call19: Codable, Sendable {
        let feature: String
        let token: String
    }
    private struct Call20: Codable, Sendable {
        let id: String
        let runId: String?
        let cursor: Int64?
        let token: String
    }
    private struct Call21: Codable, Sendable {
        let token: String
    }
    private struct Call22: Codable, Sendable {
        let token: String
        let scenario: String
    }
}

struct FeatureAskCall: Codable, Sendable {
    let generation: Int
    let payload: Data
}
