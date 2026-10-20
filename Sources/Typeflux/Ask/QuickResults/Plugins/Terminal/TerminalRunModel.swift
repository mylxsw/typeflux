import Foundation

/// One command in a built-in terminal window: its process, state and what the window
/// can do with it. The window supplies the terminal view through `output`, `visibleText`
/// and `clearScreen`; tests supply closures and a fake process instead.
@MainActor
final class TerminalRunModel: ObservableObject {
    enum Phase: Equatable {
        case running
        case finished(exitCode: Int32)
        /// The command never started: a missing directory, or no process could be created.
        case failedToStart(String)

        var isRunning: Bool {
            self == .running
        }
    }

    /// ETX: what Ctrl-C sends; the terminal turns it into SIGINT for the foreground job.
    static let interruptByte: UInt8 = 0x03
    static let hiddenInputPollInterval: TimeInterval = 0.3
    /// A command that runs this long may finish while the user is elsewhere.
    static let notificationThreshold: TimeInterval = 10

    @Published private(set) var phase: Phase = .running
    @Published private(set) var startedAt: Date
    @Published private(set) var endedAt: Date?
    @Published private(set) var readsHiddenInput = false
    /// A full-screen program (vim, top, less) is using the alternate screen.
    @Published var alternateScreen = false
    /// The first Stop sent Ctrl-C; the next one ends the command.
    @Published private(set) var interruptSent = false

    let command: String
    let settings: TerminalRunSettings
    let externalTerminal: TerminalApplication
    let launch: TerminalShellLaunch
    /// The app the launcher came from, where Insert delivers the output.
    let targetAppName: String?

    /// Feeds the terminal view; output arriving before it is attached is kept until then.
    var output: (([UInt8]) -> Void)? {
        didSet { flushPending() }
    }

    /// The normal screen's text, without trailing blank lines.
    var visibleText: () -> String = { "" }
    var clearScreen: () -> Void = {}
    /// Called once per run with the exit code and whether the window should close.
    var onFinish: ((Int32, Bool) -> Void)?

    private let makeProcess: () -> any TerminalProcess
    private let now: () -> Date
    private var process: (any TerminalProcess)?
    private var size = TerminalSize.standard
    private var pending: [[UInt8]] = []
    private var pollTimer: Timer?

    init(request: TerminalCommandRequest, settings: TerminalRunSettings, launch: TerminalShellLaunch,
         targetAppName: String?, makeProcess: @escaping () -> any TerminalProcess = { TerminalPTYProcess() },
         now: @escaping () -> Date = Date.init) {
        command = request.command
        self.settings = settings
        externalTerminal = request.terminal
        self.launch = launch
        self.targetAppName = targetAppName
        self.makeProcess = makeProcess
        self.now = now
        startedAt = now()
    }

    var isRunning: Bool {
        phase.isRunning
    }

    var directoryLabel: String {
        TerminalRunSettings.abbreviate(launch.directory, home: launch.environment["HOME"] ?? NSHomeDirectory())
    }

    var duration: TimeInterval {
        (endedAt ?? now()).timeIntervalSince(startedAt)
    }

    var hasOutput: Bool {
        !visibleText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Lifecycle

    func start() {
        let process = makeProcess()
        self.process = process
        startedAt = now()
        endedAt = nil
        phase = .running
        interruptSent = false
        readsHiddenInput = false
        process.onOutput = { [weak self, weak process] bytes in
            guard let self, let process, self.process === process else { return }
            self.receive(bytes)
        }
        process.onExit = { [weak self, weak process] code in
            guard let self, let process, self.process === process else { return }
            self.finish(code)
        }
        do {
            try process.start(launch, size: size)
        } catch {
            self.process = nil
            endedAt = now()
            phase = .failedToStart(error.localizedDescription)
            return
        }
        let timer = Timer(timeInterval: Self.hiddenInputPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHiddenInput() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Runs the same command again in this window, on a cleared screen.
    func rerun() {
        guard !isRunning else { return }
        clearScreen()
        pending.removeAll()
        alternateScreen = false
        start()
    }

    /// Ctrl-C first, as a terminal would; pressed again, it hangs the command up.
    func stop() {
        guard isRunning else { return }
        if interruptSent {
            process?.terminate()
        } else {
            interruptSent = true
            process?.write([Self.interruptByte])
        }
    }

    /// For closing the window or quitting the app: ends the command and its children.
    func terminate() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isRunning else { return }
        process?.terminate()
    }

    // MARK: - Terminal I/O

    func send(_ bytes: [UInt8]) {
        guard isRunning else { return }
        process?.write(bytes)
    }

    func resize(_ size: TerminalSize) {
        guard size.columns > 0, size.rows > 0, size != self.size else { return }
        self.size = size
        process?.resize(size)
    }

    private func receive(_ bytes: [UInt8]) {
        if let output { output(bytes) } else { pending.append(bytes) }
    }

    private func flushPending() {
        guard let output, !pending.isEmpty else { return }
        let chunks = pending
        pending.removeAll()
        chunks.forEach(output)
    }

    private func pollHiddenInput() {
        let hidden = isRunning && !alternateScreen && (process?.readsHiddenInput ?? false)
        if hidden != readsHiddenInput { readsHiddenInput = hidden }
    }

    private func finish(_ code: Int32) {
        pollTimer?.invalidate()
        pollTimer = nil
        endedAt = now()
        readsHiddenInput = false
        alternateScreen = false
        phase = .finished(exitCode: code)
        onFinish?(code, settings.finish.closesWindow(exitCode: code, hasOutput: hasOutput))
    }

    // MARK: - Presentation

    /// Shown when a run closes its window: "✓ open ~/Downloads · 0.4s".
    var completionNotice: String {
        let mark = if case .finished(0) = phase { "✓" } else { "✗" }
        return "\(mark) \(Self.truncated(command, limit: 48)) · \(Self.format(duration))"
    }

    var shouldNotify: Bool {
        settings.notifies && duration >= Self.notificationThreshold
    }

    nonisolated static func truncated(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    nonisolated static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }
}
