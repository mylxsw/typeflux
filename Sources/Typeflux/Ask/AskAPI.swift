// swiftlint:disable function_parameter_count line_length
// Preserve the existing API signatures and compatibility default bodies.
import Foundation

protocol AskAgentRuntime: Sendable {
    /// Reconciles an interrupted execution inside its existing user task.
    func recover(conversationId: String, request: AskRecoveryRequest, token: String) async throws -> AskConversation
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, maxSteps: Int?, token: String) async throws -> AskConversation
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation
    /// Continues a run paused for credits. A balance that is still empty throws
    /// `CloudCreditsExhaustedError`; repeated calls never start a second runner.
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation
}

protocol AskConversationAccess: Sendable {
    func historySyncPending(token: String) async -> Bool
    func updateTitle(id: String, request: AskTitleRequest, token: String) async throws -> AskConversation
    func list(token: String, offset: Int) async throws -> [AskConversationSummary]
    func conversation(id: String, token: String) async throws -> AskConversation
    func delete(conversationId: String, token: String) async throws
    /// Turns a temporary conversation into an ordinary one kept where it ran.
    func keep(conversationId: String, token: String) async throws -> AskConversation
    /// Moves a conversation kept on this Mac into the signed-in account's synchronized
    /// history. One-way: it is never moved back.
    func upload(conversationId: String, token: String) async throws -> AskConversation
    /// Takes over a conversation that was kept on this Mac (device engines only).
    func importConversation(_ value: AskConversation, token: String) async throws -> AskConversation
    /// Removes device memory pinned to every conversation of the signed-in user.
    func purgeMemory(token: String) async throws
    func purgeMemory(owner: String, token: String) async throws
}

protocol AskModelAccess: Sendable {
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]?
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage
    func models(token: String) async throws -> [AskCloudModel]
    func models(token: String, scenario: String) async throws -> [AskCloudModel]
}

/// Compatibility surface for existing engines and application callers.
protocol AskAPI: AskAgentRuntime, AskConversationAccess, AskModelAccess {}

extension AskAgentRuntime {
    func recover(conversationId: String, request: AskRecoveryRequest, token: String) async throws -> AskConversation {
        throw AskLocalError.message(L("ask.recovery.readOnlyUnavailable"))
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, maxSteps _: Int?, token: String) async throws -> AskConversation {
        try await retry(conversationId: conversationId, runId: runId, deviceId: deviceId, modelRef: modelRef, token: token)
    }
    /// Services without steering reject it; the device retains the intent for explicit reconciliation.
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        throw AskLocalError.message(L("ask.local.conflict"))
    }
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation {
        try await cancel(conversationId: conversationId, runId: runId, token: token)
    }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation { throw AskLocalError.message(L("ask.models.requestError")) }
}

extension AskConversationAccess {
    func historySyncPending(token: String) async -> Bool { false }
    func updateTitle(id: String, request: AskTitleRequest, token: String) async throws -> AskConversation {
        throw AskLocalError.message(L("ask.models.requestError"))
    }
    func purgeMemory(token: String) async throws {}
    func purgeMemory(owner: String, token: String) async throws { try await purgeMemory(token: token) }
    /// Services without temporary conversations have nothing to keep.
    func keep(conversationId: String, token: String) async throws -> AskConversation {
        throw AskLocalError.message(L("ask.temporary.keepFailed"))
    }
    func upload(conversationId: String, token: String) async throws -> AskConversation {
        throw AskLocalError.message(L("ask.upload.failed"))
    }
    func importConversation(_ value: AskConversation, token: String) async throws -> AskConversation {
        throw AskLocalError.message(L("ask.upload.failed"))
    }
}

extension AskModelAccess {
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]? { nil }
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        throw AskLocalError.message(L("ask.usage.unavailable"))
    }
    func models(token: String, scenario: String) async throws -> [AskCloudModel] { try await models(token: token) }
    func models(token: String) async throws -> [AskCloudModel] { [.init(id: "default", name: "Typeflux Cloud")] }
}

// These compatibility defaults need history access; runtime-only adapters provide their own.
extension AskAgentRuntime where Self: AskConversationAccess {
    /// Only Typeflux Cloud pauses for credits; elsewhere there is nothing to resume.
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws {
        while !Task.isCancelled {
            try await onValue(conversation(id: id, token: token))
            try await Task.sleep(for: .seconds(1))
        }
    }
}

// swiftlint:enable function_parameter_count line_length
