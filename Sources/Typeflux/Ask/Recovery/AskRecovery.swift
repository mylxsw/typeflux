import Foundation

/// Display metadata only. Neither the header nor this value authorizes execution.
struct AskRunRecovery: Codable, Equatable, Sendable {
    var version: Int?
    var state: String?
    var sequence: Int64?

    var blocksExecution: Bool {
        version != 1 || sequence == nil || sequence! < 0 || ![
            "queued", "running", "waiting_device", "waiting_inference",
            "budget_stopped", "completed", "failed", "cancelled"
        ].contains(state ?? "")
    }

    init(version: Int = 1, state: String, sequence: Int64) {
        self.version = version; self.state = state; self.sequence = sequence
    }

    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        version = try? values?.decode(Int.self, forKey: .version)
        state = try? values?.decode(String.self, forKey: .state)
        sequence = try? values?.decode(Int64.self, forKey: .sequence)
    }
}

struct AskExecutionIdentity: Codable, Equatable, Sendable {
    var owner: String
    var conversationId: String
    var runId: String
    var rootId: String?
    var deviceId: String
    var stepId: String
    var callId: String
    var kind: String

    var key: String {
        kind == "model" ? "inference/" + runId + "/" + callId : runId + "/" + callId
    }

    var operationId: String {
        kind == "model" ? callId : runId + "/" + callId + "/tool"
    }

    init(owner: String, conversation: AskConversation, run: AskRun, callId: String, kind: String) {
        self.owner = owner; conversationId = conversation.id; runId = run.id
        rootId = run.budgetRootId; deviceId = run.deviceId; stepId = String(run.steps)
        self.callId = callId; self.kind = kind
    }
}

/// Extends the existing SQLite claim, without persisting another copy of inputs.
/// An audit record is never imported into the in-memory approval store.
struct AskExecutionAudit: Codable, Equatable, Sendable {
    var identity: AskExecutionIdentity
    var toolVersion: String
    var toolName: String?
    var argumentsHash: String
    var approvalId: String?
    var approvedAt: Date?
    var deliveryConfirmed: Bool?
    var events: [Event] = [.claimed]

    enum Event: String, Codable, Sendable {
        case claimed, receiptSaved, retransmitting, acknowledged, ended
    }

    mutating func record(_ event: Event) {
        if event == .acknowledged {
            deliveryConfirmed = true
        }
        if events.last != event {
            events.append(event)
        }
        if events.count > 32 {
            events.removeFirst(events.count - 32)
        }
    }
}

enum AskExecutionReceipt: Equatable, Sendable {
    case tool(AskToolResultRequest)
    case inference(AskInferenceResult)

    func matches(_ identity: AskExecutionIdentity) -> Bool {
        switch self {
        case let .tool(value):
            identity.kind == "tool" && value.runId == identity.runId
                && value.deviceId == identity.deviceId && value.toolCallId == identity.callId
        case let .inference(value):
            identity.kind == "model" && value.runId == identity.runId
                && value.deviceId == identity.deviceId && value.inferenceId == identity.callId
        }
    }

    var status: String {
        switch self {
        case let .tool(value):
            if let harness = value.harness, harness.version != 1 {
                return "unknown"
            }
            return value.harness?.outcome?.safeStatus.rawValue ?? (value.isError ? "unknown" : "ok")
        case let .inference(value): return value.failed ? "unknown" : "ok"
        }
    }
}

struct AskExecutionEntry: Equatable, Sendable, Identifiable {
    var id: String
    var audit: AskExecutionAudit?
    var receipt: AskExecutionReceipt?
    var deleted = false

    var unknown: Bool {
        receipt == nil || ["unknown", "timeout", "cancelled"].contains(receipt!.status)
    }

    var acknowledged: Bool {
        audit?.deliveryConfirmed == true || audit?.events.contains(.acknowledged) == true
    }

    /// Only allow a bound record to travel with its original account and device.
    /// Legacy receipts remain readable, but missing identity is never invented.
    func permits(_ identity: AskExecutionIdentity) -> Bool {
        !deleted && audit?.identity == identity && receipt?.matches(identity) == true
    }

    /// Bounded, redacted correlations for diagnostics; no arguments, targets,
    /// provider errors, prompts, credentials or response content.
    var diagnostic: AskResultDiagnostic? {
        guard let identity = audit?.identity else { return nil }
        func redacted(_ value: String) -> String {
            String(AskToolPolicy.digest(value).prefix(23))
        }
        return .init(
            operationId: redacted(identity.operationId),
            runId: redacted(identity.runId),
            stepId: redacted(identity.stepId),
            callId: redacted(identity.callId),
            status: receipt?.status ?? "unknown",
            contentCount: receipt == nil ? 0 : 1,
            truncated: false
        )
    }
}

enum AskRecoveryError: LocalizedError {
    case unknown, binding, storage
    var errorDescription: String? {
        switch self {
        case .unknown: L("ask.recovery.unknownBody")
        case .binding: L("ask.recovery.binding")
        case .storage: L("ask.cache.failed")
        }
    }
}
