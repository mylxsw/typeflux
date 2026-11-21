import AppKit
import Combine

/// Keeps every built-in terminal window alive while it is open, and ends their commands
/// when the app quits.
@MainActor
final class TerminalSessionCenter: TerminalRunnerPresenting, ObservableObject, BackgroundActivitySource {
    static let shared = TerminalSessionCenter()
    static let cascadeOffset: CGFloat = 26

    private(set) var windows: [TerminalRunnerWindowController] = []
    private var termination: NSObjectProtocol?
    /// Builds how a command starts; tests use a shell without startup files.
    var makeLaunch: (TerminalCommandRequest, TerminalRunSettings) -> TerminalShellLaunch = { request, settings in
        TerminalShellLaunch(command: request.command, settings: settings, shell: TerminalShellLaunch.accountShell(),
                            base: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    @Published private(set) var sessions: [TerminalSession] = []
    private let feed = BackgroundActivityFeed()
    let history: TerminalCommandHistory
    private let makeProcess: () -> any TerminalProcess
    private var expiry: Timer?
    private var hiddenSince: [UUID: Date] = [:]
    var idleTimeout: TimeInterval? = 30 * 60 {
        didSet { expireIdle() }
    }

    init(
        history: TerminalCommandHistory? = nil,
        makeProcess: @escaping () -> any TerminalProcess = { TerminalPTYProcess() }
    ) {
        self.history = history ?? TerminalCommandHistory()
        self.makeProcess = makeProcess
        termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    deinit {
        if let termination {
            NotificationCenter.default.removeObserver(termination)
        }
    }

    /// Hangs up every running command; the app is quitting.
    func terminateAll() {
        for session in sessions {
            close(session)
        }
        windows.forEach { $0.model.terminate() }
    }

    func present(_ request: TerminalCommandRequest, services: TerminalRunnerServices) {
        guard let settings = request.builtin else { return }
        let launch = makeLaunch(request, settings)
        // The launcher never activates Typeflux, so the frontmost app is the one it came from.
        let target = NSWorkspace.shared.frontmostApplication
        let model = TerminalRunModel(request: request, settings: settings, launch: launch,
                                     targetAppName: target?.bundleIdentifier == Bundle.main.bundleIdentifier
                                         ? nil : target?.localizedName)
        let controller = TerminalRunnerWindowController(model: model, services: services)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        let open = windows.filter(\.window.isVisible).count
        windows.append(controller)
        controller.show(cascade: CGFloat(open) * Self.cascadeOffset)
        model.start()
    }
}

extension TerminalSessionCenter {
    func create(host: TerminalSession.Host = .launcher,
                settings: TerminalRunSettings = .init()) throws -> TerminalSession {
        let session = try TerminalSession(host: host, settings: settings, process: makeProcess(), history: history)
        session.changed = { [weak self] in
            self?.objectWillChange.send()
            self?.publish()
            self?.expireIdle()
        }
        sessions.append(session)
        return session
    }

    func move(_ session: TerminalSession, to host: TerminalSession.Host) {
        guard sessions.contains(where: { $0 === session }) else { return }
        setVisible(true, session: session)
        session.move(to: host)
    }

    func setVisible(_ visible: Bool, session: TerminalSession) {
        if visible {
            hiddenSince.removeValue(forKey: session.id)
        } else if hiddenSince[session.id] == nil {
            hiddenSince[session.id] = Date()
        }
        expireIdle()
    }

    func close(_ session: TerminalSession) {
        session.changed = nil
        session.terminate()
        sessions.removeAll { $0 === session }
        hiddenSince.removeValue(forKey: session.id)
        publish()
    }

    func expireIdle(now: Date = Date()) {
        if let idleTimeout {
            for session in sessions where session.runningBlock == nil {
                guard let hidden = hiddenSince[session.id],
                      now.timeIntervalSince(max(hidden, session.lastActivity)) >= idleTimeout else { continue }
                close(session)
            }
        }
        expiry?.invalidate()
        expiry = nil
        guard let idleTimeout else { return }
        let deadline = sessions.compactMap { session -> Date? in
            guard session.runningBlock == nil, let hidden = hiddenSince[session.id] else { return nil }
            return max(hidden, session.lastActivity).addingTimeInterval(idleTimeout)
        }.min()
        if let deadline {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.expireIdle() }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiry = timer
        }
    }

    var activitiesPublisher: AnyPublisher<[BackgroundActivity], Never> {
        feed.activitiesPublisher
    }

    var completionsPublisher: AnyPublisher<BackgroundActivityCompletion, Never> {
        feed.completionsPublisher
    }

    private func publish() {
        feed.publish(sessions.compactMap { session in
            guard let block = session.runningBlock else { return nil }
            return BackgroundActivity(
                id: block.id.uuidString,
                kind: .terminal,
                title: block.command,
                detail: session.cwd,
                state: .running,
                actions: [.stop]
            )
        })
    }

    func perform(_ action: BackgroundActivity.Action, on activityID: String) {
        guard action == .stop else { return }
        sessions.first { $0.runningBlock?.id.uuidString == activityID }?.interrupt()
    }
}
