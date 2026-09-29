import Foundation

protocol AskAPI: Sendable {
    func models(token: String) async throws -> [AskCloudModel]
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation
    func list(token: String, offset: Int) async throws -> [AskConversationSummary]
    func conversation(id: String, token: String) async throws -> AskConversation
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation
    func retry(conversationId: String, runId: String, deviceId: String, token: String) async throws -> AskConversation
    func delete(conversationId: String, token: String) async throws
}

extension AskAPI {
    func models(token: String) async throws -> [AskCloudModel] { [.init(id: "default", name: "Typeflux Cloud")] }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation { throw AskLocalError.message(L("ask.models.requestError")) }
}

struct AskAPIClient: AskAPI {
    func models(token: String) async throws -> [AskCloudModel] { try await execute(path: "/models", token: token) }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/inference-results", method: "POST", body: AskCoding.encoder().encode(request), token: token)
    }
    let executor: CloudRequestExecutor

    init(executor: CloudRequestExecutor = CloudRequestExecutor()) { self.executor = executor }

    func list(token: String, offset: Int = 0) async throws -> [AskConversationSummary] {
        try await execute(path: "?offset=\(max(0, offset))", token: token)
    }
    func conversation(id: String, token: String) async throws -> AskConversation {
        try await execute(path: "/\(id)", token: token)
    }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/messages", method: "POST", body: AskCoding.encoder().encode(request), token: token)
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/tool-results", method: "POST", body: AskCoding.encoder().encode(request), token: token)
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/cancel", method: "POST", body: JSONSerialization.data(withJSONObject: ["run_id": runId]), token: token)
    }
    func retry(conversationId: String, runId: String, deviceId: String, token: String) async throws -> AskConversation {
        try await execute(path: "/\(conversationId)/retry", method: "POST", body: JSONSerialization.data(withJSONObject: ["run_id": runId, "device_id": deviceId]), token: token)
    }
    func delete(conversationId: String, token: String) async throws {
        struct Deleted: Decodable { let deleted: Bool }
        let _: Deleted = try await execute(path: "/\(conversationId)", method: "DELETE", token: token)
    }

    private func execute<T: Decodable>(path: String, method: String = "GET", body: Data? = nil, token: String) async throws -> T {
        let path = "/api/v1/ask/conversations" + path
        let (data, response) = try await executor.execute(apiPath: path) { base in
            let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
            var components = URLComponents(url: AuthEndpointResolver.resolve(baseURL: base, path: pieces[0]), resolvingAgainstBaseURL: false)!
            if pieces.count == 2 { components.percentEncodedQuery = pieces[1] }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 200
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("ask-anything", forHTTPHeaderField: "X-Scenario")
            return request
        }
        if response.statusCode == 401 { throw AuthError.unauthorized }
        let envelope = try AskCoding.decoder().decode(APIResponse<T>.self, from: data)
        guard (200 ..< 300).contains(response.statusCode), envelope.code == "OK", let value = envelope.data else {
            throw AuthError.serverError(code: envelope.code, message: envelope.message)
        }
        return value
    }
}
