import Foundation

/// Only interrupt the conversation when its current task needs a user decision.
struct AskRecoveryPresentation: Equatable {
    let unknown: Bool
    let otherDevice: Bool
    let active: Bool
    let savedReceipts: Int
    let canContinue: Bool

    init(run: AskRun?, entries: [AskExecutionEntry], deviceId: String, local _: Bool) {
        // Keep historical evidence in the journal without treating an earlier
        // task's outcome as a problem with the user's current request.
        let currentEntries = entries.filter { $0.audit == nil || $0.audit?.identity.runId == run?.id }
        unknown = run?.needsRecoveryInspection == true || currentEntries.contains { $0.unknown || $0.audit == nil }
        otherDevice = run.map { $0.deviceId != deviceId } ?? false
        active = run?.isActive == true
        savedReceipts = currentEntries.filter { !$0.deleted && $0.receipt != nil && !$0.acknowledged }.count
        canContinue = !unknown && savedReceipts == 0 && !otherDevice
            && ["waiting_tool", "waiting_inference"].contains(run?.status ?? "")
    }

    var isVisible: Bool {
        unknown || savedReceipts > 0 || canContinue
    }

    var titleKey: String {
        if unknown {
            return "ask.recovery.unknown"
        }
        if otherDevice && (active || savedReceipts > 0) {
            return "ask.recovery.otherDevice"
        }
        if savedReceipts > 0 {
            return "ask.recovery.saved"
        }
        return active ? "ask.recovery.paused" : "ask.recovery.finished"
    }

    var bodyKey: String {
        if unknown {
            return "ask.recovery.unknownBody"
        }
        if otherDevice && (active || savedReceipts > 0) {
            return "ask.recovery.binding"
        }
        if savedReceipts > 0 {
            return "ask.recovery.savedBody"
        }
        return active ? "ask.recovery.activeBody" : "ask.recovery.finishedBody"
    }
}
