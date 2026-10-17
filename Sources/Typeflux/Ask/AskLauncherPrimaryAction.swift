import Foundation

/// The visible Return action. Readiness disables an intent instead of replacing it with Chat.
struct AskLauncherPrimaryAction: Equatable {
    var mode: AskLauncherChatAction
    var enabled = true
    var disabledReason: String?

    var title: String { mode.title }

    /// Disabled only until the newest input's results arrive. Typing passes through
    /// this state on every keystroke, so the button is drawn as ready meanwhile.
    var waiting: Bool { !enabled && disabledReason == L("ask.launcher.action.wait") }
    var hint: String { enabled ? mode.hint : disabledReason ?? L("ask.launcher.action.unavailable") }

    static func confirm(_ title: String, enabled: Bool = true, reason: String? = nil) -> Self {
        Self(mode: .execute(title), enabled: enabled, disabledReason: reason)
    }

    static func chat(draft: AskDraft, canSend: Bool, canOpen: Bool, loadingAttachments: Bool) -> Self {
        let mode = AskLauncherChatAction.resolve(draft: draft, loadingAttachments: loadingAttachments)
        let enabled = mode == .openChat ? canOpen : canSend
        return Self(mode: mode, enabled: enabled,
                    disabledReason: loadingAttachments || draft.canSend || mode == .openChat
                        ? L("ask.openChat.wait") : L("ask.launcher.action.input"))
    }

    static func quickResult(_ results: AskQuickResults, pending: Bool, chat: Self) -> Self {
        let action: Self
        switch results.highlightedRow {
        case .askAI: action = chat
        case .calculation, .format:
            action = .confirm(L("ask.launcher.action.copyResult"), enabled: results.isEnabled(results.highlightedRow))
        case .showAllFiles: action = .confirm(L("ask.quick.file.showAll"))
        case let .feature(index):
            action = .confirm(results.features[index].title)
        case .browser: action = .confirm(L("ask.quick.action.open"))
        case .file:
            action = .confirm(L("ask.launcher.action.open", results.file(at: results.highlightedRow)?.name ?? ""))
        case .app, .pane:
            action = .confirm(L("ask.launcher.action.open", results.app(at: results.highlightedRow)?.name ?? ""))
        }
        guard pending else { return action }
        var waiting = action
        waiting.enabled = false
        waiting.disabledReason = L("ask.launcher.action.wait")
        return waiting
    }

    static func plugin(_ display: AskPluginDisplay, current: Bool, canAskAI: Bool,
                       canRunWithoutInput: Bool = false) -> Self {
        if display.asksAI { return Self(mode: .askAI, enabled: canAskAI) }
        if let hint = display.hint {
            return hint.pluginID == AskOpenChatPlugin.id
                ? Self(mode: .openChat, enabled: canAskAI) : .confirm(display.title)
        }
        if display.translation {
            let output = display.output ?? display.partial
            if !current || output?.translation?.submitted == false {
                return .confirm(L("ask.plugin.translate.title"))
            }
            if case let .running(plan) = display.phase {
                if plan.values["submitted"] != "true" { return .confirm(L("ask.plugin.translate.title")) }
                let copy = output?.action(for: .enter)
                return .confirm(copy?.title ?? display.title, enabled: copy != nil,
                                reason: L("ask.launcher.action.wait"))
            }
        }
        let action: AskPluginAction?
        switch display.phase {
        case .waiting:
            if canRunWithoutInput { return .confirm(L("ask.launcher.action.run", display.title)) }
            return .confirm(display.title, enabled: false, reason: L("ask.launcher.action.input"))
        case let .ready(plan):
            action = plan.action(for: .enter)
            return .confirm(action?.title ?? L("ask.launcher.action.run", display.title), enabled: current,
                            reason: L("ask.launcher.action.wait"))
        case let .running(plan):
            action = plan.action(for: .enter)
        case let .done(_, output):
            action = output.action(for: .enter)
        case let .failed(_, failure):
            action = failure.action(for: .enter)
            if action == nil, failure.retry {
                return .confirm(L("ask.plugin.action.retry"), enabled: current, reason: L("ask.launcher.action.wait"))
            }
        }
        return .confirm(action?.title ?? display.title, enabled: current && action != nil,
                        reason: current ? L("ask.launcher.action.unavailable") : L("ask.launcher.action.wait"))
    }
}

/// Suppresses duplicate activations while still allowing a new target or a second confirmation.
struct AskLauncherActivationGate {
    struct Target: Equatable {
        var mode: AskLauncherChatAction
        var text: String
        var selection: String
        var confirming: Bool
    }

    private var previous: (target: Target, time: TimeInterval)?

    mutating func accept(_ target: Target, now: TimeInterval) -> Bool {
        if let previous, previous.target == target, now - previous.time < 0.25 { return false }
        previous = (target, now)
        return true
    }
}
