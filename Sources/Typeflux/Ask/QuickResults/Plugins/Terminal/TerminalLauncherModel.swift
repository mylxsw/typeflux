import AppKit
import Combine

/// Presentation state for one persistent shell. The center owns the shell and its lifetime.
@MainActor
final class TerminalLauncherModel: ObservableObject {
    enum Prompt: Equatable {
        case idle, running, input, secure, ended
    }

    let explanation: TerminalFailureExplanation
    let session: TerminalSession
    let settings: TerminalRunSettings
    let source: NSRunningApplication?
    @Published var text = "" {
        didSet {
            if oldValue != text { pendingRisk = nil }
        }
    }
    @Published private(set) var pendingRisk: TerminalCommandRisk?
    @Published private(set) var completionCandidates: [String] = []
    private var completion = TerminalCompletion()
    var completionSelection: String? { completion.selectedCandidate }
    @Published var secret = ""
    @Published private(set) var selected: UUID?
    @Published private(set) var collapsed: Set<UUID> = []
    private var history = History()
    private var observation: AnyCancellable?
    private var pendingBlock: UUID?
    private var lastPrompt = Prompt.idle

    init(session: TerminalSession, settings: TerminalRunSettings, source: NSRunningApplication?,
         notify: @escaping @MainActor (String, String) async -> Bool,
         visible: @escaping @MainActor () -> Bool, explanation: TerminalFailureExplanation? = nil) {
        self.explanation = explanation ?? TerminalFailureExplanation()
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
        if current != .idle { pendingRisk = nil }
        if current != lastPrompt {
            resetCompletion()
            if current == .idle || current == .secure || lastPrompt == .input { text = "" }
            secret = ""
            lastPrompt = current
        }
    }

    @discardableResult
    func submit() -> Bool {
        resetCompletion()
        switch prompt {
        case .idle:
            guard pendingRisk == nil, TerminalCommandRequest.problem(with: text) == nil else { return false }
            if settings.confirmsRisky, let risk = TerminalCommandRisk.detect(text) {
                pendingRisk = risk
                return false
            }
            return runCommand()
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

    @discardableResult
    func confirmRisk() -> Bool {
        guard pendingRisk != nil, prompt == .idle else { return false }
        pendingRisk = nil
        return runCommand()
    }

    @discardableResult
    func cancelRisk() -> Bool {
        guard pendingRisk != nil, prompt == .idle else { return false }
        pendingRisk = nil
        session.recordCancellation(text)
        fill("")
        return true
    }

    private func runCommand() -> Bool {
        guard session.submit(text) else { return false }
        fill("")
        selected = nil
        return true
    }

    func complete() -> Bool {
        if canTabToExplanation, fillExplanation() { return true }
        guard prompt == .idle, pendingRisk == nil,
              let completed = completion.advance(text, cwd: session.cwd, path: session.searchPath) else {
            resetCompletion()
            return false
        }
        text = completed
        completionCandidates = completion.candidates
        history = History()
        return true
    }

    @discardableResult
    func resetCompletion() -> Bool {
        let hadCandidates = !completionCandidates.isEmpty
        completion = TerminalCompletion()
        if hadCandidates { completionCandidates = [] }
        return hadCandidates
    }

    func recall(_ delta: Int, commands: [String]) {
        guard prompt == .idle else { return }
        resetCompletion()
        text = history.move(delta, commands: commands, current: text)
    }

    func fill(_ command: String) {
        resetCompletion()
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
        return session.blocks.last {
            $0.endedAt != nil && $0.state != .cancelled
                && (settings.insert == .commandAndOutput || $0.output.length > 0)
        }
    }

    func insertSelected(using deliver: (String) -> Void) {
        guard let block = actionBlock else { return }
        insert(block, using: deliver)
    }

    func insert(_ block: TerminalCommandBlock, using deliver: (String) -> Void) {
        guard block.state != .cancelled else { return }
        let text = settings.insertion(command: block.command, output: block.output.string)
        if !text.isEmpty { deliver(text) }
    }

    var canTabToExplanation: Bool {
        text.isEmpty && (selected == nil || selected == explanation.blockID)
    }

    @discardableResult
    func fillExplanation() -> Bool {
        guard prompt == .idle, pendingRisk == nil, case let .ready(answer) = explanation.phase,
              let id = explanation.blockID, session.blocks.contains(where: { $0.id == id && $0.canExplain })
        else { return false }
        fill(answer.command)
        return true
    }

    func clear() {
        explanation.clear()
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
        case .interrupted, .cancelled: return mark(block)
        }
    }

    static func mark(_ block: TerminalCommandBlock) -> String {
        if block.state == .cancelled { return L("terminal.risk.cancelled") }
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
