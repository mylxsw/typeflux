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
    private let readGitStatus: (String) async -> TerminalGitStatus?
    private let makeProcess: () -> any TerminalProcess
    private var defaults: UserDefaults { history.defaults }
    private let finderDirectory: @MainActor () -> String?
    static let lastDirectoryKey = "terminal.lastSessionDirectory"
    private var expiry: Timer?
    private var hiddenSince: [UUID: Date] = [:]
    var idleTimeout: TimeInterval? = 30 * 60 {
        didSet { expireIdle() }
    }

    init(
        history: TerminalCommandHistory? = nil,
        makeProcess: @escaping () -> any TerminalProcess = { TerminalPTYProcess() },
        readGitStatus: @escaping (String) async -> TerminalGitStatus? = TerminalGitStatus.read,
        finderDirectory: (@MainActor () -> String?)? = nil
    ) {
        self.history = history ?? TerminalCommandHistory()
        self.makeProcess = makeProcess
        self.readGitStatus = readGitStatus
        self.finderDirectory = finderDirectory ?? Self.frontFinderDirectory
        termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    deinit {
        expiry?.invalidate()
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
        var launch = makeLaunch(request, settings)
        launch.directory = startingPath(for: settings)
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
    func startingPath(for settings: TerminalRunSettings) -> String {
        settings.startingPath(
            home: NSHomeDirectory(), last: defaults.string(forKey: Self.lastDirectoryKey),
            finder: { finderDirectory() },
            isDirectory: { path in
                var directory: ObjCBool = false
                return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                    && directory.boolValue
            }
        )
    }

    private static func frontFinderDirectory() -> String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty else {
            return nil
        }
        let script = NSAppleScript(source: """
        tell application id "com.apple.finder"
            if (count of Finder windows) is 0 then return POSIX path of (desktop as alias)
            return POSIX path of (target of front Finder window as alias)
        end tell
        """)
        var error: NSDictionary?
        return script?.executeAndReturnError(&error).stringValue
    }

    func create(host: TerminalSession.Host = .launcher,
                settings: TerminalRunSettings = .init()) throws -> TerminalSession {
        let session = try TerminalSession(host: host, settings: settings, process: makeProcess(), history: history,
                                          startingPath: startingPath(for: settings), readGitStatus: readGitStatus)
        rememberDirectory(session.cwd)
        session.directoryChanged = { [weak self] in self?.rememberDirectory($0) }
        session.changed = { [weak self] in
            guard let self else { return }
            objectWillChange.send()
            publish()
            expireIdle()
        }
        sessions.append(session)
        return session
    }

    private func rememberDirectory(_ path: String) {
        if path != defaults.string(forKey: Self.lastDirectoryKey) { defaults.set(path, forKey: Self.lastDirectoryKey) }
    }

    func move(_ session: TerminalSession, to host: TerminalSession.Host) {
        guard sessions.contains(where: { $0 === session }) else { return }
        setVisible(true, session: session)
        session.move(to: host)
    }

    func setVisible(_ visible: Bool, session: TerminalSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        if visible {
            hiddenSince.removeValue(forKey: session.id)
            rememberDirectory(session.cwd)
        } else if hiddenSince[session.id] == nil {
            hiddenSince[session.id] = Date()
        }
        expireIdle()
    }

    func close(_ session: TerminalSession) {
        session.changed = nil
        session.directoryChanged = nil
        session.terminate()
        sessions.removeAll { $0 === session }
        hiddenSince.removeValue(forKey: session.id)
        publish()
    }

    func expireIdle(now: Date = Date()) {
        for session in sessions where idleDeadline(for: session).map({ $0 <= now }) == true {
            close(session)
        }
        expiry?.invalidate()
        expiry = nil
        let deadline = sessions.compactMap { idleDeadline(for: $0) }.min()
        if let deadline {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.expireIdle() }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiry = timer
        }
    }

    private func idleDeadline(for session: TerminalSession) -> Date? {
        guard session.runningBlock == nil, let hidden = hiddenSince[session.id] else { return nil }
        let timeout: TimeInterval? = switch session.settings.idle {
        case .thirtyMinutes: idleTimeout
        case .always: nil
        case .never: 0
        }
        return timeout.map { max(hidden, session.lastActivity).addingTimeInterval($0) }
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
