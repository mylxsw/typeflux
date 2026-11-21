import AppKit
import SwiftTerm

struct TerminalCommandBlock: Identifiable {
    enum State { case running, waitingForInput, hiddenInput, alternateScreen, finished, interrupted }
    let id = UUID()
    let command: String
    let cwd: String
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var state = State.running
    var output = NSAttributedString(string: "")
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Host: Equatable { case launcher, window(UUID) }
    let id = UUID()
    @Published private(set) var host: Host
    @Published private(set) var cwd: String
    @Published private(set) var blocks: [TerminalCommandBlock] = []
    @Published private(set) var exited = false
    @Published private(set) var git: TerminalGitStatus?
    @Published private(set) var alternateScreen = false
    var runningBlock: TerminalCommandBlock? {
        blocks.last.flatMap { $0.endedAt == nil ? $0 : nil }
    }

    var readsHiddenInput: Bool {
        runningBlock?.state == .hiddenInput
    }

    private(set) lazy var terminalView = TerminalRunnerTerminalView(session: self)
    private(set) var lastActivity: Date
    var changed: (() -> Void)?

    private let shell: TerminalSessionShell
    private let process: any TerminalProcess
    private let history: TerminalCommandHistory
    private var stream = TerminalMarkerStream()
    private var integrated = false
    private var closing = false
    private var interruptSent = false
    private var inputPrompt = false
    private var ready = false
    private var pending: String?
    private var gitTask: Task<Void, Never>?
    private var poll: Timer?

    init(host: Host, settings: TerminalRunSettings, process: any TerminalProcess,
         history: TerminalCommandHistory) throws {
        self.host = host
        self.process = process
        self.history = history
        shell = try TerminalSessionShell(settings: settings)
        let launch = shell.launch(settings: settings)
        cwd = launch.directory
        lastActivity = Date()
        process.onOutput = { [weak self] in self?.receive($0) }
        process.onExit = { [weak self] code in
            guard let self else { return }
            exited = true
            finish(code)
            poll?.invalidate()
            changed?()
        }
        try process.start(launch, size: .standard)
    }

    private func pollWhileRunning() {
        let timer = Timer(timeInterval: TerminalRunModel.hiddenInputPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInput() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func move(to host: Host) {
        self.host = host
        lastActivity = Date()
    }

    @discardableResult
    func submit(_ command: String) -> Bool {
        guard !closing, !exited, runningBlock == nil, TerminalCommandRequest.problem(with: command) == nil,
              !process.readsHiddenInput else { return false }
        lastActivity = Date()
        blocks.append(TerminalCommandBlock(command: command, cwd: cwd, startedAt: lastActivity))
        pollWhileRunning()
        interruptSent = false
        inputPrompt = false
        pending = command
        if ready {
            flushCommand()
        } else {
            // Custom startup files may suppress all integration markers. Leave
            // their shell connected and treat its lifetime as one command block.
            let id = runningBlock?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, runningBlock?.id == id else { return }
                flushCommand()
            }
        }
        changed?()
        return true
    }

    private func flushCommand() {
        guard let command = pending, !exited, !process.readsHiddenInput else { return }
        pending = nil
        history.record(command)
        // A markerless shell with line editing disabled reads a plain canonical
        // line. Escape wrappers would become part of its command.
        let paste = integrated || terminalView.getTerminal().bracketedPasteMode
        let line = paste ? "\u{1b}[200~" + command + "\u{1b}[201~" : command
        process.write(Array((line + "\r").utf8))
    }

    func write(_ bytes: [UInt8]) {
        guard !closing, !exited else { return }
        inputPrompt = false
        process.write(bytes)
    }

    func eof() {
        write([4])
    }

    func resize(_ size: TerminalSize) {
        process.resize(size)
    }

    func interrupt() {
        guard runningBlock != nil else { return }
        if interruptSent {
            terminate()
            return
        }
        interruptSent = true
        if pending != nil {
            pending = nil
            finish(130, captureOutput: false)
        } else {
            write([3])
        }
    }

    func terminate() {
        poll?.invalidate()
        gitTask?.cancel()
        pending = nil
        if !exited, !closing {
            closing = true
            process.terminate()
        }
    }

    private func receive(_ bytes: [UInt8]) {
        for event in stream.read(bytes) {
            switch event {
            case let .bytes(chunk):
                terminalView.feed(byteArray: chunk[...])
                let alternate = terminalView.getTerminal().isCurrentBufferAlternate
                if alternate != alternateScreen {
                    alternateScreen = alternate
                }
                if runningBlock != nil {
                    // A canonical-mode prompt often ends without a line break.
                    let tail = String(decoding: chunk.suffix(80), as: UTF8.self)
                    inputPrompt = [": ", "? ", "> "].contains(where: tail.hasSuffix)
                    refreshInput()
                }
            case let .directory(path):
                if cwd != path {
                    cwd = path
                    git = nil
                }
            case .prompt:
                integrated = true
                refreshGit()
            case .input:
                ready = true
                flushCommand()
            case .output:
                integrated = true
                ready = false
                // The active emulator now shows only this block's output.
                terminalView.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
            case let .complete(code):
                if integrated {
                    finish(code)
                }
            }
        }
    }

    func refreshInput() {
        guard let block = runningBlock else { return }
        let state: TerminalCommandBlock.State = alternateScreen ? .alternateScreen :
            process.readsHiddenInput ? .hiddenInput : inputPrompt ? .waitingForInput : .running
        if state != block.state {
            blocks[blocks.count - 1].state = state
            changed?()
        }
    }

    private func finish(_ code: Int32, captureOutput: Bool = true) {
        guard var block = runningBlock else { return }
        lastActivity = Date()
        poll?.invalidate()
        poll = nil
        block.endedAt = lastActivity
        block.exitCode = code
        block.state = interruptSent ? .interrupted : .finished
        if captureOutput { block.output = terminalView.blockSnapshot() }
        blocks[blocks.count - 1] = block
        changed?()
    }

    private func refreshGit() {
        gitTask?.cancel()
        let path = cwd
        gitTask = Task {
            let result = await TerminalGitStatus.read(path)
            if !Task.isCancelled, path == cwd {
                git = result
            }
        }
    }
}
