import Foundation
import TypefluxChat

protocol AskAPI: Sendable {
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]?
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws
    func models(token: String) async throws -> [AskCloudModel]
    func models(token: String, scenario: String) async throws -> [AskCloudModel]
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation
    func list(token: String, offset: Int) async throws -> [AskConversationSummary]
    func conversation(id: String, token: String) async throws -> AskConversation
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation
    /// Continues a run paused for credits. A balance that is still empty throws
    /// `CloudCreditsExhaustedError`; repeated calls never start a second runner.
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation
    func delete(conversationId: String, token: String) async throws
    /// Removes device memory pinned to every conversation of the signed-in user.
    func purgeMemory(token: String) async throws
    func purgeMemory(owner: String, token: String) async throws
}

extension AskAPI {
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]? { nil }
    /// Services without steering reject it; the device then sends the message as a new turn.
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        throw AskLocalError.message(L("ask.local.conflict"))
    }
    /// Only Typeflux Cloud pauses for credits; elsewhere there is nothing to resume.
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        throw AskLocalError.message(L("ask.usage.unavailable"))
    }
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation {
        try await cancel(conversationId: conversationId, runId: runId, token: token)
    }
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws {
        while !Task.isCancelled {
            try await onValue(conversation(id: id, token: token))
            try await Task.sleep(for: .seconds(1))
        }
    }

    func models(token: String, scenario: String) async throws -> [AskCloudModel] { try await models(token: token) }
    func models(token: String) async throws -> [AskCloudModel] { [.init(id: "default", name: "Typeflux Cloud")] }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation { throw AskLocalError.message(L("ask.models.requestError")) }
    func purgeMemory(token: String) async throws {}
    func purgeMemory(owner: String, token: String) async throws { try await purgeMemory(token: token) }
}

struct AskAPIClient: AskAPI {
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        var path = "/\(id)/usage?cursor=\(cursor ?? 0)"
        if let runId { path += "&run_id=" + (runId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
        return try await execute(path: path, token: token)
    }
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]? {
        struct Catalog: Decodable { let configured: Bool; let models: [AskCloudModel]? }
        let encoded = feature.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? feature
        let path = "/api/v1/cloud-models?feature=" + encoded
        let (data, response) = try await executor.execute(apiPath: path) { base in
            ChatRequest.make(baseURL: base, path: path, method: "GET", body: nil, token: token,
                             headers: ["X-Typeflux-Model-Catalog": "1"])
        }
        if response.statusCode == 404 { return nil }
        let catalog: Catalog = try ChatRequest.decode(data: data, statusCode: response.statusCode)
        return catalog.configured ? (catalog.models ?? []) : nil
    }
    func models(token: String, scenario: String) async throws -> [AskCloudModel] {
        try await execute(path: "/models?scenario=" + (scenario == "rewrite" ? "rewrite" : "ask"), token: token)
    }
    func models(token: String) async throws -> [AskCloudModel] { try await execute(path: "/models", token: token) }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/inference-results", method: "POST", body: AskCoding.encoder().encode(request), token: token)
    }
    let executor: CloudRequestExecutor
    let recoveryMetadataEnabled: Bool
    let streamSession: URLSession
    private let trustedPeer: AskHarnessContract?
    private let enabledCapabilities: Set<AskHarnessCapability>

    init(executor: CloudRequestExecutor = CloudRequestExecutor(), streamSession: URLSession = .shared,
         trustedPeer: AskHarnessContract? = nil, enabledCapabilities: Set<AskHarnessCapability> = [],
         recoveryMetadataEnabled: Bool = false) {
        self.recoveryMetadataEnabled = recoveryMetadataEnabled
        self.trustedPeer = trustedPeer; self.enabledCapabilities = enabledCapabilities
        self.executor = executor; self.streamSession = streamSession
    }

    func list(token: String, offset: Int = 0) async throws -> [AskConversationSummary] {
        try await execute(path: "?offset=\(max(0, offset))", token: token)
    }
    func conversation(id: String, token: String) async throws -> AskConversation {
        try await execute(path: "/\(id)", token: token)
    }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        if request.clientToolApproval == true { try await requireToolApproval(token: token) }
        return try await execute(path: "/\(conversationId)/messages", method: "POST", body: AskCoding.encoder().encode(request), token: token)
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        let wire = request.forPeer(trustedPeer, enabled: enabledCapabilities)
        var response: AskConversation = try await execute(path: "/\(conversationId)/tool-results", method: "POST", body: AskCoding.encoder().encode(wire), token: token)
        // Keep the local receipt visible even when an old server only echoes legacy fields.
        if request.approveExecution == nil, let index = response.messages.firstIndex(where: { $0.role == "tool" && $0.toolCallId == request.toolCallId }),
           response.messages[index].harness == nil {
            response.messages[index].harness = request.harness
            response.messages[index].runId = request.runId
        }
        return response
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/cancel", method: "POST", body: JSONSerialization.data(withJSONObject: ["run_id": runId]), token: token)
    }
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation {
        struct Request: Encodable { var runId: String; var partial: AskInferenceResult? }
        return try await execute(path: "/\(conversationId)/cancel", method: "POST", body: AskCoding.encoder().encode(Request(runId: runId, partial: partial)), token: token)
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String? = nil, token: String) async throws -> AskConversation {
        try await requireToolApproval(token: token)
        struct Request: Encodable { var runId: String; var deviceId: String; var modelRef: String?; var clientToolApproval = true }
        return try await execute(path: "/\(conversationId)/retry", method: "POST", body: AskCoding.encoder().encode(Request(runId: runId, deviceId: deviceId, modelRef: modelRef)), token: token)
    }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation {
        if request.clientToolApproval == true { try await requireToolApproval(token: token) }
        return try await execute(path: "/\(conversationId)/regenerate", method: "POST", body: AskCoding.encoder().encode(request), token: token)
    }
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/steer", method: "POST", body: AskCoding.encoder().encode(request), token: token)
    }
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        let run = runId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? runId
        return try await execute(path: "/\(conversationId)/runs/\(run)/resume", method: "POST", body: Data("{}".utf8), token: token)
    }
    func delete(conversationId: String, token: String) async throws {
        struct Deleted: Decodable { let deleted: Bool }
        let _: Deleted = try await execute(path: "/\(conversationId)", method: "DELETE", token: token)
    }
    func purgeMemory(token: String) async throws {
        struct Purged: Decodable { let purged: Int }
        let _: Purged = try await execute(path: "/memory", method: "DELETE", token: token)
    }

    private func requireToolApproval(token: String) async throws {
        struct Capability: Decodable { var version: Int }
        let capability: Capability = try await execute(path: "/tool-approval", token: token)
        guard capability.version == 1 else { throw AskLocalError.message(L("ask.mode.serverUpgrade")) }
    }

    private func execute<T: Decodable>(path: String, method: String = "GET", body: Data? = nil, token: String) async throws -> T {
        let path = ChatRequest.conversationsPath + path
        let (data, response) = try await executor.execute(apiPath: path) { base in
            var headers = ["X-Typeflux-Model-Catalog": "1", "X-Scenario": "ask-anything"]
            if recoveryMetadataEnabled { headers["X-Typeflux-Capabilities"] = "run_recovery_v1" }
            return ChatRequest.make(baseURL: base, path: path, method: method, body: body,
                                        token: token, headers: headers)
        }
        if !(200..<300).contains(response.statusCode), let exhausted = CloudCreditsExhaustedError.parse(data: data) {
            throw exhausted
        }
        do { return try ChatRequest.decode(data: data, statusCode: response.statusCode) }
        catch ChatAPIError.unauthorized { throw AuthError.unauthorized }
        catch let ChatAPIError.server(code, message) { throw AuthError.serverError(code: code, message: message) }
        catch { throw AuthError.invalidResponse }
    }
}
