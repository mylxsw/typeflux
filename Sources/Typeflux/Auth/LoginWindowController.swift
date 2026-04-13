import AppKit
import SwiftUI

@MainActor
final class LoginWindowController: NSObject {
    static let shared = LoginWindowController()

    private let windowSize = NSSize(width: 520, height: 480)
    private var window: NSWindow?
    private var hostingView: NSHostingView<LoginView>?
    private var appearanceObserver: NSObjectProtocol?
    private let settingsStore = SettingsStore()

    override init() {
        super.init()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                window.appearance = AppAppearance.nsAppearance(for: self.settingsStore.appearanceMode)
            }
        }
    }

    func show() {
        if let window {
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentRect = NSRect(origin: .zero, size: windowSize)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        let loginView = LoginView(
            onDismiss: { [weak self] in
                self?.window?.close()
            }
        )
        let hosting = NSHostingView(rootView: loginView)
        // Prevent NSHostingView from driving the window size via intrinsic content size
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]

        window.title = L("auth.login.windowTitle")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(StudioTheme.windowBackground)
        window.contentView = hosting
        // Lock the window to a fixed size (no resizing)
        window.minSize = windowSize
        window.maxSize = windowSize
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)

        hostingView = hosting
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension LoginWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
        }
        window = nil
        hostingView = nil
    }
}
