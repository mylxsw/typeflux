import AppKit

/// System permission and session UI must not replace the user's source application.
@MainActor
final class AskSourceApplicationTracker {
    static let shared = AskSourceApplicationTracker()
    private var previous: ReadOnlySelectionRequest?
    private var activationObserver: NSObjectProtocol?
    private let ownProcessID: pid_t
    private let isRunning: (pid_t) -> Bool

    init(observeWorkspace: Bool = true, ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
         isRunning: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }) {
        self.ownProcessID = ownProcessID
        self.isRunning = isRunning
        guard observeWorkspace else { return }
        record(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.record(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private func record(_ app: NSRunningApplication?) {
        guard let app else { return }
        record(.init(processID: app.processIdentifier, processName: app.localizedName,
                     bundleIdentifier: app.bundleIdentifier),
               regular: app.activationPolicy == .regular)
    }

    func record(_ request: ReadOnlySelectionRequest, regular: Bool) {
        guard regular, let processID = request.processID, processID != ownProcessID,
              !Self.isSystemUI(request) else { return }
        previous = request
    }

    func resolve(_ request: ReadOnlySelectionRequest) -> ReadOnlySelectionRequest {
        guard Self.isSystemUI(request) else { return request }
        guard var previous, let processID = previous.processID, isRunning(processID) else { return .init() }
        previous.id = request.id
        // Keep only the source identity. No selection is read from an app behind a system dialog.
        previous.nativeSnapshot = TextSelectionSnapshot(source: "system-ui-fallback")
        return previous
    }

    static func isSystemUI(_ request: ReadOnlySelectionRequest) -> Bool {
        let names = ["usernotificationcenter", "universalaccessauthwarn", "loginwindow", "screensaver",
                     "screensaverengine", "securityagent", "authorizationhost", "coreservicesuiagent"]
        let name = request.processName?.lowercased() ?? ""
        let bundle = request.bundleIdentifier?.lowercased() ?? ""
        return names.contains(name) || names.contains { bundle == "com.apple." + $0 }
            || bundle.hasPrefix("com.apple.screensaver.")
    }
}
