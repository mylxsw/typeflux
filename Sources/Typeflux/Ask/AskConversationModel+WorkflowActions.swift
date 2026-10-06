import AppKit
import Foundation

/// What a workflow's actions did after one run: the bottom bar's summary, and the
/// clipboard as it was before the first copy so ⌘Z can put it back.
struct AskWorkflowActionsState: Equatable {
    /// The run the actions belong to (`AskWorkflowFollowUp.id`).
    var id: UUID
    var outcomes: [AskWorkflowActionOutcome]
    var clipboard: AskClipboardSnapshot?
    var undone = false

    var summary: String {
        AskWorkflowActionRunner.summary(outcomes)
    }

    var canUndo: Bool {
        clipboard != nil && !undone
    }

    var failed: Bool {
        outcomes.contains {
            if case .failed = $0.status {
                true
            } else {
                false
            }
        }
    }
}

/// A workflow's script wants to open a web host the workflow does not name: the
/// launcher asks once ("Exchange Rates wants to open xe.com. Allow?").
struct AskWorkflowApproval: Equatable, Identifiable {
    var id = UUID()
    var workflowName: String
    var host: String
}

/// Every item on a pasteboard with each of its types, to restore it later.
struct AskClipboardSnapshot: Equatable {
    var items: [[String: Data]]

    @MainActor
    static func take(_ pasteboard: NSPasteboard) -> AskClipboardSnapshot {
        AskClipboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } },
                       uniquingKeysWith: { first, _ in first })
        })
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}

/// The launcher's side of a workflow's actions. Writing back, opening and asking the
/// AI close the launcher; notes after that appear in a small panel instead of the bar.
@MainActor
final class AskWorkflowLauncherActionHost: AskWorkflowActionHost {
    private weak var model: AskConversationModel?
    private let dismiss: () -> Void
    /// The workflow whose actions these are: approvals are remembered for it.
    private let workflowID: String?
    private let workflowName: String
    private(set) var closed = false
    /// A `runKeyword` put another run in the launcher; it is that run's now, not ours to close.
    private(set) var handedOff = false
    /// The clipboard before this run's first copy.
    private(set) var clipboard: AskClipboardSnapshot?

    init(model: AskConversationModel, workflowID: String? = nil, workflowName: String = "",
         dismiss: @escaping () -> Void) {
        self.model = model
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.dismiss = dismiss
    }

    /// Leaves keyword mode and closes the launcher, once.
    func close() {
        guard !closed else { return }
        closed = true
        model?.finishPluginResult()
        dismiss()
    }

    func copy(_ text: String) {
        if clipboard == nil {
            clipboard = AskClipboardSnapshot.take(AskQuickResults.pasteboard)
        }
        AskQuickResults.copy(text)
    }

    func writeBack(_ text: String) {
        close()
        model?.writeBack(text)
    }

    func notify(title: String, body: String) async -> Bool {
        await model?.notifyUser(title, body) ?? false
    }

    /// In the bar while the launcher is open (the summary carries it), else a small panel.
    func hud(_ text: String) {
        if closed {
            model?.passiveNotice(text)
        }
    }

    func open(_ target: AskWorkflowOpenTarget) -> Bool {
        guard let model else { return false }
        switch target {
        case let .link(url), let .file(url):
            close()
            model.openURL(url)
            return true
        case let .application(name):
            guard model.openApplicationNamed(name) else { return false }
            close()
            return true
        }
    }

    func reveal(_ url: URL) -> Bool {
        model?.revealFile(url)
        return model != nil
    }

    func speak(_ text: String, language: String?) {
        model?.speak(text, language ?? AskWorkflowLauncherActionHost.language(of: text))
    }

    func askAI(_ prompt: String) {
        closed = true
        model?.askAIFromPlugin(prompt)
        dismiss()
    }

    func runKeyword(_ keyword: String, argument: String, chain: [String]) -> Bool {
        guard !closed, let model, model.runLauncherKeyword(keyword, argument: argument, chain: chain) else {
            return false
        }
        handedOff = true
        return true
    }

    /// Asked in the launcher's bottom bar while it is open; a yes is remembered for this
    /// workflow. Once the launcher has closed there is no one to ask: no.
    func approve(host: String) async -> Bool {
        guard let model, let workflowID else { return false }
        let settings = model.modelLibrary.settings
        if settings.askWorkflowAllowedHosts[workflowID]?.contains(host) == true { return true }
        guard !closed, !handedOff else { return false }
        let allowed = await model.requestWorkflowApproval(AskWorkflowApproval(workflowName: workflowName, host: host))
        if allowed {
            settings.askWorkflowAllowedHosts[workflowID, default: []].append(host)
        }
        return allowed
    }

    /// The language a text is most likely in, for the system voice.
    static func language(of text: String) -> String {
        AskLanguageDetector().detect(text, hints: []) ?? Locale.current.identifier
    }

    /// Opens an application by bundle id, or by name from the usual folders.
    static func openApplication(_ name: String) -> Bool {
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: name) ?? applicationURL(named: name)
        guard let url else { return false }
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Opens a file or folder with an application found as `openApplication` finds it.
    static func open(_ url: URL, inApplication name: String) -> Bool {
        let workspace = NSWorkspace.shared
        guard let application = workspace.urlForApplication(withBundleIdentifier: name) ?? applicationURL(named: name)
        else { return false }
        workspace.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    static func applicationURL(named name: String, fileManager: FileManager = .default) -> URL? {
        let file = name.hasSuffix(".app") ? name : name + ".app"
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}

extension AskConversationModel {
    /// Runs a workflow's actions after its run, once per run. `dismiss` closes the
    /// launcher; it is called when an action leaves it or the workflow says to close.
    func performWorkflowFollowUp(_ followUp: AskWorkflowFollowUp, dismiss: @escaping () -> Void) {
        guard workflowActions?.id != followUp.id else { return }
        workflowActions = AskWorkflowActionsState(id: followUp.id, outcomes: [])
        answerWorkflowApproval(false)
        let workflow = plugins.plugin as? AskWorkflowPlugin
        let host = AskWorkflowLauncherActionHost(model: self, workflowID: workflow?.workflow.id,
                                                 workflowName: workflow?.title ?? "", dismiss: dismiss)
        Task { @MainActor [weak self] in
            let outcomes = await AskWorkflowActionRunner.run(followUp.steps, host: host)
            guard let self, workflowActions?.id == followUp.id else { return }
            workflowActions = AskWorkflowActionsState(id: followUp.id, outcomes: outcomes, clipboard: host.clipboard)
            AskAnnouncer.announce(AskWorkflowActionRunner.summary(outcomes))
            if followUp.closes, !host.handedOff {
                host.close()
            }
        }
    }

    /// The actions' summary for the result on screen; nil once another result replaced it.
    var currentWorkflowActions: AskWorkflowActionsState? {
        guard let state = workflowActions, !state.outcomes.isEmpty else { return nil }
        let shown: AskWorkflowFollowUp? = switch plugins.phase {
        case let .done(_, output): output.followUp
        case let .failed(_, failure): failure.followUp
        default: nil
        }
        return shown?.id == state.id ? state : nil
    }

    /// Shows `approval` in the launcher's bottom bar and waits for ↩ (allow) or esc. A
    /// question still open is answered no first.
    func requestWorkflowApproval(_ approval: AskWorkflowApproval) async -> Bool {
        answerWorkflowApproval(false)
        return await withCheckedContinuation { continuation in
            workflowApproval = approval
            workflowApprovalReply = { continuation.resume(returning: $0) }
        }
    }

    /// Answers the open question, if there is one; leaving the result answers no.
    func answerWorkflowApproval(_ allowed: Bool) {
        let reply = workflowApprovalReply
        workflowApprovalReply = nil
        if workflowApproval != nil {
            workflowApproval = nil
        }
        reply?(allowed)
    }

    /// ⌘Z after a workflow copied something: the clipboard as it was. False when there is nothing to undo.
    func undoWorkflowCopy() -> Bool {
        guard var state = currentWorkflowActions, state.canUndo, let clipboard = state.clipboard else { return false }
        clipboard.restore(to: AskQuickResults.pasteboard)
        state.undone = true
        workflowActions = state
        AskAnnouncer.announce(L("ask.workflow.action.copyUndone"))
        return true
    }
}

extension SettingsStore {
    /// Web hosts each workflow's script actions may open without asking, by workflow
    /// id: the ones the user allowed in the launcher.
    var askWorkflowAllowedHosts: [String: [String]] {
        get { (defaults.dictionary(forKey: "ask.workflows.allowedHosts") as? [String: [String]]) ?? [:] }
        set { defaults.set(newValue, forKey: "ask.workflows.allowedHosts") }
    }
}
