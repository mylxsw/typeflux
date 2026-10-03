import Foundation

/// Frozen by GUL-166. These DTOs do not enable or authorize execution.
/// See docs/harness/contract-v1.md before wiring a capability into a runner.
struct AskHarnessContract: Codable, Equatable, Sendable {
    var version: Int
    var capabilities: [String]? = nil
    var context: AskExecutionContext? = nil
    var approval: AskApprovalScope? = nil
    var outcome: AskExecutionOutcome? = nil
    var observation: AskObservationRef? = nil
    var workspace: AskWorkspaceRef? = nil
    var process: AskProcessRef? = nil
    var artifacts: [AskArtifactRef]? = nil
    var budget: AskRunBudget? = nil
    var recoveryClass: String? = nil

    /// An explicit local rollout flag AND both peers are required. Unknown
    /// capabilities/versions never activate a new path. P00 enables none.
    func permits(_ capability: AskHarnessCapability, peer: AskHarnessContract?,
                 enabled: Set<AskHarnessCapability> = []) -> Bool {
        version == 1 && peer?.version == 1 && enabled.contains(capability) &&
            (capabilities ?? []).contains(capability.rawValue) &&
            (peer?.capabilities ?? []).contains(capability.rawValue)
    }
}

enum AskHarnessCapability: String, CaseIterable, Sendable {
    case scopedApproval = "scoped_approval_v1"
    case typedContent = "typed_content_v1"
    case observationTarget = "observation_target_v1"
    case workspaceRefs = "workspace_refs_v1"
}

struct AskExecutionTarget: Codable, Equatable, Sendable {
    var kind: String
    var id: String
    var version: String? = nil
    var path: String? = nil
    var domain: String? = nil
}

struct AskExecutionContext: Codable, Equatable, Sendable {
    var ownerId: String
    var conversationId: String
    var runId: String
    var stepId: String
    var toolCallId: String
    var toolName: String
    var toolVersion: String
    var argumentsHash: String
    var target: AskExecutionTarget
    var deadline: Date
    var serverId: String? = nil
    var serverVersion: String? = nil
    var approvalId: String? = nil
    var idempotencyKey: String? = nil
}

/// A persisted description, not a grant validator. Trusted policy code must
/// validate ownership, target, arguments, expiry, revocation and consumption.
struct AskApprovalScope: Codable, Equatable, Sendable {
    var id: String
    var ownerId: String
    var conversationId: String
    var action: String
    var target: AskExecutionTarget
    var expiresAt: Date
    var singleUse: Bool
    var argumentsHash: String? = nil
    var allowedArguments: JSONValue? = nil
    var consumedAt: Date? = nil
    var revokedAt: Date? = nil
}

enum AskExecutionStatus: String, CaseIterable, Sendable {
    case ok, denied, invalid, timeout, cancelled, unknown
}

struct AskExecutionOutcome: Codable, Equatable, Sendable {
    /// Keep the raw value readable across versions; never interpret an unknown
    /// value as success or permission to retry a side effect.
    var status: String
    var content: [JSONValue]? = nil
    var artifacts: [AskArtifactRef]? = nil
    var durationMs: Int64? = nil
    var eventDispatched: Bool? = nil
    var effectVerified: Bool? = nil
    var truncated: Bool? = nil

    var safeStatus: AskExecutionStatus { AskExecutionStatus(rawValue: status) ?? .unknown }
}

struct AskObservationRef: Codable, Equatable, Sendable {
    var id: String
    var target: AskExecutionTarget
    var capturedAt: Date
    var appId: String? = nil
    var processInstanceId: String? = nil
    var pid: Int? = nil
    var windowId: String? = nil
    var displayId: String? = nil
    var browserId: String? = nil
    var tabId: String? = nil
    var documentGeneration: String? = nil
    var invalidationReason: String? = nil
}

struct AskWorkspaceRef: Codable, Equatable, Sendable {
    var id: String
    var ownerId: String
    var conversationId: String
    var runId: String
    var version: String
    var cleanup: String
}

struct AskProcessRef: Codable, Equatable, Sendable {
    var id: String
    var ownerId: String
    var conversationId: String
    var runId: String
    var workspaceId: String
    var instanceId: String
    var startedAt: Date
    var cleanup: String
    var pid: Int? = nil
    var processGroupId: Int? = nil
}

struct AskArtifactRef: Codable, Equatable, Sendable {
    var id: String
    var ownerId: String
    var conversationId: String
    var runId: String
    var version: String
    var mediaType: String
    var sizeBytes: Int64
    var sha256: String
    var cleanup: String
    var expiresAt: Date? = nil
}

/// Reserved for later budget enforcement; no durable worker is enabled here.
struct AskRunBudget: Codable, Equatable, Sendable {
    var limits: [String: Int64]
    var used: [String: Int64]
    var reserved: [String: Int64]
}
