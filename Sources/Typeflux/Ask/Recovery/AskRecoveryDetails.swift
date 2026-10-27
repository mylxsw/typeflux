import Foundation

/// Facts for the inspector, not a diagnosis inferred from assistant narration.
/// Missing records never prove that an effect did not happen.
struct AskRecoveryDetails: Equatable {
    enum Reason: Equatable {
        case storage, otherDevice, timedOut, interrupted, missingResult, savedResults, inspectionBlocked
        case stepLimit, stopped, unrecorded
        case modelFailure(String)
    }

    let reason: Reason
    let step: Int
    let savedResults: Int
    let unconfirmedResults: Int
    let completedPlanItems: Int
    let totalPlanItems: Int
    let nextPlanStep: String?
    let inspectionExplanation: String?
    let pendingKind: String?

    /// Generic status, progress counts and action descriptions are already in
    /// the conversation. They do not justify another button or modal.
    var hasUsefulDetails: Bool {
        switch reason {
        case .timedOut, .interrupted, .modelFailure, .stepLimit, .storage:
            true
        case .inspectionBlocked:
            inspectionExplanation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .unrecorded, .stopped, .missingResult, .savedResults, .otherDevice:
            false
        }
    }

    init(conversation: AskConversation?, entries: [AskExecutionEntry], deviceId: String) {
        let run = conversation?.run
        let current = entries.filter {
            $0.audit?.identity.runId == run?.id && $0.audit?.identity.conversationId == conversation?.id
                && $0.audit != nil && !$0.deleted
        }
        let unbound = entries.filter { $0.audit == nil && !$0.readUnavailable && !$0.deleted }
        step = max(0, run?.steps ?? 0)
        savedResults = current.count(where: { $0.receipt != nil })
        unconfirmedResults = current.count(where: { $0.needsInspection(run: run) }) + unbound.count
        let plan = run?.plan ?? []
        completedPlanItems = plan.count(where: { $0.status == "completed" })
        totalPlanItems = plan.count
        nextPlanStep = (plan.first { $0.status == "in_progress" } ?? plan.first { $0.status != "completed" })
            .map { String($0.step.prefix(400)) }
        pendingKind = Self.pendingKind(run)
        inspectionExplanation = run?.internalRecovery?.phase == .blocked
            ? run?.internalRecovery?.explanation.map { String($0.prefix(1000)) } : nil
        reason = Self.reason(run: run, entries: entries, current: current, deviceId: deviceId)
    }

    private static func pendingKind(_ run: AskRun?) -> String? {
        if run?.status == "waiting_inference" { return "model" }
        guard let name = run?.pending.first?.function.name else { return nil }
        return switch name {
        case "browser", "computer": name
        case "run_command", "command_job": "command"
        default: "other"
        }
    }

    private static func reason(
        run: AskRun?,
        entries: [AskExecutionEntry],
        current: [AskExecutionEntry],
        deviceId: String
    ) -> Reason {
        if entries.contains(where: \.readUnavailable) { return .storage }
        if let run, run.deviceId != deviceId { return .otherDevice }
        if run?.internalRecovery?.phase == .blocked { return .inspectionBlocked }
        let unbound = entries.contains { $0.audit == nil && !$0.readUnavailable && !$0.deleted }
        if let failure = failureReason(run: run, current: current, unbound: unbound) { return failure }
        if current.contains(where: { $0.receipt != nil && !$0.acknowledged }) { return .savedResults }
        if run?.reachedStepLimit == true { return .stepLimit }
        if run?.status == "cancelled" { return .stopped }
        return .unrecorded
    }

    private static func failureReason(run: AskRun?, current: [AskExecutionEntry], unbound: Bool) -> Reason? {
        let uncertain = current.filter { $0.needsInspection(run: run) }
        if run?.errorCode == "MODEL_TIMEOUT" || uncertain
            .contains(where: { $0.receipt?.status == "timeout" }) { return .timedOut }
        if uncertain.contains(where: { $0.receipt?.status == "cancelled" }) { return .interrupted }
        if let key = run?.failureLocalizationKey { return .modelFailure(key) }
        if unbound || !uncertain.isEmpty || run?.needsRecoveryInspection == true { return .missingResult }
        return nil
    }

    var reasonKey: String {
        switch reason {
        case .storage: "ask.recovery.detail.reason.storage"
        case .otherDevice: "ask.recovery.detail.reason.device"
        case .timedOut: "ask.recovery.detail.reason.timeout"
        case .interrupted: "ask.recovery.detail.reason.interrupted"
        case .missingResult: "ask.recovery.detail.reason.missing"
        case .savedResults: "ask.recovery.detail.reason.saved"
        case .inspectionBlocked: "ask.recovery.detail.reason.blocked"
        case .stepLimit: "ask.recovery.detail.reason.limit"
        case .stopped: "ask.recovery.detail.reason.stopped"
        case .unrecorded: "ask.recovery.detail.reason.unrecorded"
        case let .modelFailure(key): key
        }
    }
}

extension AskConversationModel {
    var recoveryDetails: AskRecoveryDetails {
        .init(conversation: selected, entries: selectedRecoveryEntries, deviceId: deviceId)
    }
}

extension AskRecoveryAction {
    var detailKey: String {
        switch self {
        case .continueRun: "ask.recovery.detail.action.continue"
        case .checkAndContinue: "ask.recovery.detail.action.check"
        case .refresh: "ask.recovery.detail.action.refresh"
        case .stop: "ask.recovery.detail.action.stop"
        case .selfCheck: "ask.recovery.detail.action.return"
        }
    }
}
