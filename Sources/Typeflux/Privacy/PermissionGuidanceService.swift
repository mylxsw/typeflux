import AppKit
import Combine
import PermissionFlow

/// Navigation only: callers retain ownership of system prompts and permission checks.
@MainActor
final class PermissionGuidanceService {
    static let shared: PermissionGuidanceService = {
        let controller = PermissionFlow.makeController(configuration: .init(promptForAccessibilityTrust: false))
        return PermissionGuidanceService(
            isGranted: { permission in
                switch permission {
                case .accessibility: PrivacyGuard.isAccessibilityGranted()
                case .screenRecording: ScreenCapturePermission.live.isGranted
                case .fullDiskAccess: AskFullDiskAccess.isGranted()
                default: false
                }
            },
            present: { permission, appURL, locale in
                let pane: PermissionFlowPane
                switch permission {
                case .accessibility: pane = .accessibility
                case .screenRecording: pane = .screenRecording
                case .fullDiskAccess: pane = .fullDiskAccess
                default: return
                }
                controller.setLocaleIdentifier(locale)
                let mouse = NSEvent.mouseLocation
                controller.authorize(
                    pane: pane, suggestedAppURLs: [appURL],
                    sourceFrameInScreen: CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
                )
            },
            close: { controller.closePanel() },
            updateLocale: { controller.setLocaleIdentifier($0) },
            openURL: { _ = NSWorkspace.shared.open($0) },
            bundleURL: { Bundle.main.bundleURL },
            locale: { AppLocalization.shared.language.localeIdentifier }
        )
    }()

    private let isGranted: (SettingsPermission) -> Bool
    private let present: (SettingsPermission, URL, String) -> Void
    private let close: () -> Void
    private let updateLocale: (String) -> Void
    private let openURL: (URL) -> Void
    private let bundleURL: () -> URL
    private let locale: () -> String
    private let now: () -> Date
    private let monitorsSystem: Bool
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var deadline: Date?
    private(set) var activePermission: SettingsPermission?

    init(
        isGranted: @escaping (SettingsPermission) -> Bool,
        present: @escaping (SettingsPermission, URL, String) -> Void,
        close: @escaping () -> Void,
        updateLocale: @escaping (String) -> Void,
        openURL: @escaping (URL) -> Void,
        bundleURL: @escaping () -> URL,
        locale: @escaping () -> String,
        now: @escaping () -> Date = Date.init,
        monitorsSystem: Bool = true
    ) {
        self.isGranted = isGranted
        self.present = present
        self.close = close
        self.updateLocale = updateLocale
        self.openURL = openURL
        self.bundleURL = bundleURL
        self.locale = locale
        self.now = now
        self.monitorsSystem = monitorsSystem
    }

    deinit { timer?.invalidate() }

    /// Also handles existing URL-based launcher actions without changing their data model.
    func open(_ url: URL) {
        guard let permission = SettingsPermission.allCases.first(where: { $0.settingsURL == url }) else {
            openURL(url)
            return
        }
        show(permission)
    }

    func show(_ permission: SettingsPermission) {
        dismiss()
        let appURL = bundleURL()
        guard [.accessibility, .screenRecording, .fullDiskAccess].contains(permission),
              appURL.pathExtension.lowercased() == "app", !isGranted(permission) else {
            openURL(permission.settingsURL)
            return
        }
        activePermission = permission
        // Bound polling even if the user closes the library's panel and never returns.
        deadline = now().addingTimeInterval(300)
        present(permission, appURL, locale())
        if monitorsSystem { startMonitoring() }
    }

    func refresh() {
        guard let permission = activePermission else { return }
        if isGranted(permission) || deadline.map({ now() >= $0 }) == true {
            dismiss()
        } else {
            updateLocale(locale())
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        subscriptions.removeAll()
        deadline = nil
        guard activePermission != nil else { return }
        activePermission = nil
        close()
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.dismiss() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == "com.apple.systempreferences" { self?.dismiss() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .appLanguageDidChange)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }
}
