import Foundation

/// Application entry point with independently replaceable runtime, history and catalog services.
struct AskApplicationAPI: AskAPI {
    let runtime: any AskAgentRuntime
    let conversations: any AskConversationAccess
    let modelAccess: any AskModelAccess

    /// Retains the existing token-based local/cloud routing for every capability.
    static func routed(cloud: any AskAPI, local: any AskAPI) -> AskApplicationAPI {
        do {
            let registry = try AskAgentRegistry(registrations: [
                .init(descriptor: .default, runtime: local)
            ], defaultBinding: .default)
            let composedLocal = try AskApplicationAPI(registry: registry, conversations: local, modelAccess: local)
            let routed = AskRoutedAPI(cloud: cloud, local: composedLocal)
            return .init(runtime: routed, conversations: routed, modelAccess: routed)
        } catch {
            preconditionFailure("Invalid default Ask runtime composition")
        }
    }

    func updateTitle(id: String, request: AskTitleRequest, token: String) async throws -> AskConversation {
        try await conversations.updateTitle(id: id, request: request, token: token)
    }

    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        try await modelAccess.usage(id: id, runId: runId, cursor: cursor, token: token)
    }
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation {
        try await runtime.cancel(conversationId: conversationId, runId: runId, partial: partial, token: token)
    }
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws {
        try await runtime.observe(id: id, token: token, onValue: onValue)
    }
    func models(token: String) async throws -> [AskCloudModel] { try await modelAccess.models(token: token) }
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]? {
        try await modelAccess.featureModels(feature: feature, token: token)
    }
    func models(token: String, scenario: String) async throws -> [AskCloudModel] { try await modelAccess.models(token: token, scenario: scenario) }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation {
        try await runtime.inferenceResult(conversationId: conversationId, request: request, token: token)
    }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] { try await conversations.list(token: token, offset: offset) }
    func conversation(id: String, token: String) async throws -> AskConversation { try await conversations.conversation(id: id, token: token) }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        try await runtime.send(conversationId: conversationId, request: request, token: token)
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        try await runtime.result(conversationId: conversationId, request: request, token: token)
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await runtime.cancel(conversationId: conversationId, runId: runId, token: token)
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation {
        try await runtime.retry(conversationId: conversationId, runId: runId, deviceId: deviceId,
                                modelRef: modelRef, token: token)
    }
    // The compatibility API retains its existing retry parameters.
    // swiftlint:disable:next function_parameter_count
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?,
               maxSteps: Int?, token: String) async throws -> AskConversation {
        try await runtime.retry(conversationId: conversationId, runId: runId, deviceId: deviceId,
                                modelRef: modelRef, maxSteps: maxSteps, token: token)
    }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation {
        try await runtime.regenerate(conversationId: conversationId, request: request, token: token)
    }
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        try await runtime.steer(conversationId: conversationId, request: request, token: token)
    }
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await runtime.resume(conversationId: conversationId, runId: runId, token: token)
    }
    func delete(conversationId: String, token: String) async throws { try await conversations.delete(conversationId: conversationId, token: token) }
    func keep(conversationId: String, token: String) async throws -> AskConversation {
        try await conversations.keep(conversationId: conversationId, token: token)
    }

    func purgeMemory(token: String) async throws {
        try await conversations.purgeMemory(token: token)
    }
    func purgeMemory(owner: String, token: String) async throws {
        try await conversations.purgeMemory(owner: owner, token: token)
    }
}

extension AskApplicationAPI {
    /// Validate the complete runtime contract before publishing an application API.
    /// Production callers supply only the canonical default local registration.
    init(registry: AskAgentRegistry, conversations: any AskConversationAccess, modelAccess: any AskModelAccess) throws {
        let selected = try registry.selectDefault(requiredOperations: Set(AskAgentOperation.allCases))
        self.init(runtime: selected.runtime, conversations: conversations, modelAccess: modelAccess)
    }
}
