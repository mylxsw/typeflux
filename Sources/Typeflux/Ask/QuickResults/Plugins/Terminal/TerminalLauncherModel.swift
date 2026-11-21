import AppKit
import Combine

/// Presentation state for one persistent shell. The center owns the shell and its lifetime.
@MainActor
final class TerminalLauncherModel: ObservableObject {
    enum Prompt: Equatable {
        case idle, running, input, secure, ended
    }

    let session: TerminalSession
    let settings: TerminalRunSettings
    let source: NSRunningApplication?
    @Published var text = ""
    @Published var secret = ""
    @Published private(set) var selected: UUID?
    @Published private(set) var collapsed: Set<UUID> = []
    private var history = History()
    private var observation: AnyCancellable?
    private var pendingBlock: UUID?
    private var lastPrompt = Prompt.idle

    init(session: TerminalSession, settings: TerminalRunSettings, source: NSRunningApplication?,
         notify: @escaping @MainActor (String, String) async -> Bool,
         visible: @escaping @MainActor () -> Bool) {
        self.session = session
        self.settings = settings
        self.source = source
        observation = session.$blocks.sink { [weak self] blocks in
            guard let self else { return }
            if let block = blocks.last, block.endedAt == nil {
                pendingBlock = block.id
            } else if let id = pendingBlock {
                pendingBlock = nil
                if settings.notifies, !visible(), let block = blocks.last, block.id == id,
                   let message = Self.backgroundCompletion(block) {
                    Task { _ = await notify(L("terminal.launcher.notification"), message) }
                }
            }
        }
    }

    var prompt: Prompt {
        if session.exited { return .ended }
        switch session.runningBlock?.state {
        case nil: return .idle
        case .waitingForInput: return .input
        case .hiddenInput: return .secure
        default: return .running
        }
    }

    func synchronizePrompt() {
        let current = prompt
        if current != lastPrompt {
            if current == .idle || current == .secure || lastPrompt == .input { text = "" }
            secret = ""
            lastPrompt = current
        }
    }

    @discardableResult
    func submit() -> Bool {
        switch prompt {
        case .idle:
            guard session.submit(text) else { return false }
            history = History()
            text = ""
            selected = nil
        case .input, .secure:
            let hidden = prompt == .secure
            let line = hidden ? secret : text
            secret = ""
            guard session.writeInputLine(line, hidden: hidden) else { return false }
            text = ""
        case .running, .ended:
            return false
        }
        return true
    }

    func recall(_ delta: Int, commands: [String]) {
        guard prompt == .idle else { return }
        text = history.move(delta, commands: commands, current: text)
    }

    func fill(_ command: String) {
        text = command
        history = History()
    }

    func select(_ delta: Int) {
        let ids = session.blocks.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        let next = max(0, index + delta)
        selected = ids.indices.contains(next) ? ids[next] : nil
    }

    func deselect() -> Bool {
        guard selected != nil else { return false }
        selected = nil
        return true
    }

    var actionBlock: TerminalCommandBlock? {
        if let selected { return session.blocks.first { $0.id == selected && $0.endedAt != nil } }
        return session.blocks.last { $0.endedAt != nil && $0.output.length > 0 }
    }

    func insertSelected(using deliver: (String) -> Void) {
        guard let text = actionBlock?.output.string, !text.isEmpty else { return }
        deliver(text)
    }

    func clear() {
        selected = nil
        collapsed = []
        session.clearFinishedBlocks()
    }

    func toggleCollapsed(_ id: UUID) {
        if !collapsed.insert(id).inserted { collapsed.remove(id) }
    }

    static func backgroundCompletion(_ block: TerminalCommandBlock) -> String? {
        guard let end = block.endedAt else { return nil }
        let duration = end.timeIntervalSince(block.startedAt)
        guard duration >= TerminalRunModel.notificationThreshold else { return nil }
        let command = TerminalRunModel.truncated(block.command, limit: 80)
        return "\(mark(block)) \(command) · \(TerminalRunModel.format(duration))"
    }

    static func homeStatus(_ block: TerminalCommandBlock) -> String? {
        switch block.state {
        case .waitingForInput, .hiddenInput: return L("terminal.launcher.waiting")
        case .running, .alternateScreen:
            return TerminalRunModel.format(Date().timeIntervalSince(block.startedAt))
        case .finished: return block.exitCode == 0 ? nil : mark(block)
        case .interrupted: return mark(block)
        }
    }

    static func mark(_ block: TerminalCommandBlock) -> String {
        if block.state == .interrupted { return "⌃C" }
        guard let code = block.exitCode else { return "" }
        return code == 0 ? "✓" : "✗ \(code)"
    }

    struct History {
        private var index = -1
        private var draft = ""

        mutating func move(_ delta: Int, commands: [String], current: String) -> String {
            if index == -1 { draft = current }
            index = min(max(-1, index + delta), commands.count - 1)
            return index == -1 ? draft : commands[index]
        }

        static func suggestion(for text: String, commands: [String]) -> String? {
            guard !text.isEmpty else { return nil }
            return commands.first { $0.hasPrefix(text) && $0 != text }
        }
    }
}
