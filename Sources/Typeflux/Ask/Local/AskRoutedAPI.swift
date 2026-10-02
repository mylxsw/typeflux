import Foundation

/// Sends each Ask call to Typeflux Cloud or to the on-device engine. Local
/// sessions carry an empty token, so routing needs no extra state and an
/// account switch (which changes the session owner) resets the conversation model.
struct AskRoutedAPI: AskAPI {
    static let localOwner = "local"

    let cloud: any AskAPI
    let local: any AskAPI

    private func api(_ token: String) -> any AskAPI { token.isEmpty ? local : cloud }

    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        try await api(token).usage(id: id, runId: runId, cursor: cursor, token: token)
    }
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation {
        try await api(token).cancel(conversationId: conversationId, runId: runId, partial: partial, token: token)
    }
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws {
        try await api(token).observe(id: id, token: token, onValue: onValue)
    }
    func models(token: String) async throws -> [AskCloudModel] { try await api(token).models(token: token) }
    func models(token: String, scenario: String) async throws -> [AskCloudModel] { try await api(token).models(token: token, scenario: scenario) }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation {
        try await api(token).inferenceResult(conversationId: conversationId, request: request, token: token)
    }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] { try await api(token).list(token: token, offset: offset) }
    func conversation(id: String, token: String) async throws -> AskConversation { try await api(token).conversation(id: id, token: token) }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        try await api(token).send(conversationId: conversationId, request: request, token: token)
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        try await api(token).result(conversationId: conversationId, request: request, token: token)
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await api(token).cancel(conversationId: conversationId, runId: runId, token: token)
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation {
        try await api(token).retry(conversationId: conversationId, runId: runId, deviceId: deviceId, modelRef: modelRef, token: token)
    }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation {
        try await api(token).regenerate(conversationId: conversationId, request: request, token: token)
    }
    func delete(conversationId: String, token: String) async throws { try await api(token).delete(conversationId: conversationId, token: token) }

    /// Local copies are always cleared; Cloud copies only with a Cloud session.
    func purgeMemory(token: String) async throws {
        try await local.purgeMemory(token: "")
        if !token.isEmpty { try await cloud.purgeMemory(token: token) }
    }

    /// The Cloud session when signed in and local mode is off; otherwise the local session.
    static func session(localMode: Bool, token: String?, owner: String?) -> (owner: String, token: String) {
        guard !localMode, let token, !token.isEmpty, let owner, !owner.isEmpty else { return (localOwner, "") }
        return (owner, token)
    }
}
