import AppKit
import CoreGraphics

/// Screen Recording access. Reading it never prompts; only an explicit user action
/// (a screenshot button, a settings toggle) may request it.
protocol ScreenCapturePermissionProviding {
    /// A read-only check.
    var isGranted: Bool { get }
    /// Requests access unless it is already granted. The request also lists Typeflux in
    /// System Settings → Screen & System Audio Recording, which `isGranted` never does.
    /// - Returns: whether access is granted.
    @discardableResult
    func request() -> Bool
    /// Requests access only the first time it is found missing, so the system prompt
    /// shows at most once; later calls stay silent.
    func requestOnce()
    func openSystemSettings()
}

extension ScreenCapturePermissionProviding {
    /// Requests access and opens System Settings only when it is still missing.
    func requestOrOpenSettings() {
        if !request() { openSystemSettings() }
    }

    /// Registers Typeflux first, otherwise the settings pane shows no Typeflux entry.
    func registerAndOpenSettings() {
        request()
        openSystemSettings()
    }
}

final class ScreenCapturePermission: ScreenCapturePermissionProviding {
    static let live = ScreenCapturePermission()
    static let requestedKey = "ask.screenCaptureAccessRequested"
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    private let defaults: UserDefaults
    private let preflight: () -> Bool
    private let requestAccess: () -> Bool
    private let openURL: (URL) -> Void

    init(defaults: UserDefaults = .standard,
         preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         requestAccess: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.preflight = preflight
        self.requestAccess = requestAccess
        self.openURL = openURL
    }

    var isGranted: Bool { preflight() }

    @discardableResult
    func request() -> Bool {
        preflight() || requestAccess()
    }

    func requestOnce() {
        guard !preflight(), !defaults.bool(forKey: Self.requestedKey) else { return }
        defaults.set(true, forKey: Self.requestedKey)
        _ = requestAccess()
    }

    func openSystemSettings() {
        if let url = Self.settingsURL { openURL(url) }
    }
}
