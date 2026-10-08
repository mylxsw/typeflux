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
        unknown = run?.needsRecoveryInspection == true || currentEntries.contains { $0.needsInspection(run: run) }
        otherDevice = run.map { $0.deviceId != deviceId } ?? false
        active = run?.isActive == true
        savedReceipts = currentEntries.filter { !$0.deleted && $0.receipt != nil && !$0.acknowledged }.count
        canContinue = !unknown && savedReceipts == 0 && !otherDevice
            && ["waiting_tool", "waiting_inference"].contains(run?.status ?? "")
    }

    var isVisible: Bool {
        unknown || savedReceipts > 0 || canContinue
    }

    var canEnd: Bool { isVisible && active && !otherDevice }

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

/// What the user can do about a run that waits for a recovery decision.
enum AskRecoveryAction: Equatable, CaseIterable {
    /// Ends the uncertain run and starts one that checks before continuing.
    case checkAndContinue
    /// Delivers results saved on this Mac; was "Update conversation".
    case refresh
    case continueRun
    /// The user checks the outcome themselves and returns to the conversation.
    case selfCheck
    case stop

    /// The button title, on the card and as the inspector's primary button.
    var titleKey: String {
        switch self {
        case .checkAndContinue: "ask.recovery.checkAndContinue"
        case .refresh: "ask.recovery.retransmit"
        case .continueRun: "ask.recovery.continue"
        case .selfCheck: "ask.recovery.close"
        case .stop: "ask.recovery.end"
        }
    }

    /// The option card's title and description in the inspector.
    var optionTitleKey: String {
        switch self {
        case .checkAndContinue: "ask.recovery.option.check"
        case .refresh: "ask.recovery.option.refresh"
        case .continueRun: "ask.recovery.option.continue"
        case .selfCheck: "ask.recovery.option.self"
        case .stop: "ask.recovery.option.stop"
        }
    }

    var optionBodyKey: String {
        switch self {
        case .checkAndContinue: "ask.recovery.option.checkBody"
        case .refresh: "ask.recovery.option.refreshBody"
        case .continueRun: "ask.recovery.activeBody"
        case .selfCheck: "ask.recovery.checkBody"
        case .stop: "ask.recovery.endBody"
        }
    }

    /// After the run stopped, checking yourself is only about telling Typeflux what remains.
    func optionBodyKey(active: Bool) -> String {
        self == .selfCheck && !active ? "ask.recovery.followUpBody" : optionBodyKey
    }

    var isDestructive: Bool { self == .stop }
}

extension AskRecoveryPresentation {
    /// The card's buttons: one primary action, Stop, and "Learn more".
    struct Actions: Equatable {
        var primary: AskRecoveryAction?
        var stop: Bool
        var details: Bool
    }

    /// `canRetransmit` and `canContinue` are what this Mac can actually do now.
    func actions(canRetransmit: Bool, canContinue: Bool) -> Actions {
        let primary: AskRecoveryAction? = if unknown {
            otherDevice ? nil : .checkAndContinue
        } else if savedReceipts > 0 {
            // "Refresh progress" exists only while there is saved progress to deliver.
            canRetransmit ? .refresh : nil
        } else if canContinue, self.canContinue {
            .continueRun
        } else {
            nil
        }
        return Actions(primary: primary, stop: canEnd, details: isVisible)
    }

    /// The inspector's choices, the recommended one first; Stop only while it applies.
    func options(canRetransmit: Bool, canContinue: Bool) -> [AskRecoveryAction] {
        let actions = actions(canRetransmit: canRetransmit, canContinue: canContinue)
        var options: [AskRecoveryAction] = []
        if let primary = actions.primary { options.append(primary) }
        if unknown, !otherDevice { options.append(.selfCheck) }
        if actions.stop { options.append(.stop) }
        return options
    }
}

/// Where the run stopped, as a short timeline for the inspector. Uses the run's
/// own plan when it has one; otherwise only counts steps, so no tool names,
/// targets or arguments are shown.
struct AskRecoveryTimeline: Equatable {
    enum State: Equatable { case done, current, upcoming }

    struct Item: Equatable {
        var title: String
        var detail: String?
        var state: State
    }

    var items: [Item]

    init(run: AskRun?, unknown: Bool) {
        guard let run else { items = []; return }
        let currentKey = unknown ? "ask.recovery.timeline.unknown" : "ask.recovery.timeline.paused"
        if let plan = run.plan, !plan.isEmpty {
            var items: [Item] = []
            var marked = false
            for (index, entry) in plan.enumerated() {
                let detail = L("ask.activity.step", index + 1)
                if entry.status == "completed" {
                    items.append(.init(title: entry.step, detail: detail, state: .done))
                } else if !marked {
                    marked = true
                    items.append(.init(title: entry.step + " · " + L(currentKey), detail: detail, state: .current))
                } else {
                    items.append(.init(title: entry.step, detail: detail, state: .upcoming))
                }
            }
            self.items = items
            return
        }
        let current = max(run.steps, 1)
        var items: [Item] = []
        if current > 1 {
            items.append(.init(title: L("ask.recovery.timeline.done", current - 1), detail: nil, state: .done))
        }
        items.append(.init(title: L("ask.activity.step", current) + " · " + L(currentKey), detail: nil,
                           state: .current))
        self.items = items
    }
}
