import AppKit
import SwiftUI

/// The background tasks window, opened from the menu's task section.
@MainActor
final class BackgroundActivityWindowController: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.background-activity")

    private let center: BackgroundActivityCenter
    private let settingsStore: SettingsStore
    private(set) var window: NSWindow?
    private var languageObserver: NSObjectProtocol?

    init(center: BackgroundActivityCenter, settingsStore: SettingsStore) {
        self.center = center
        self.settingsStore = settingsStore
        super.init()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    func show(activate: Bool = true) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.identifier = Self.identifier
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 460, height: 360)
            window.center()
            self.window = window
            reload()
        }
        guard let window else { return }
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
    }

    private func reload() {
        guard let window else { return }
        window.title = L("activity.window.title")
        window.contentView = NSHostingView(rootView: BackgroundActivityWindowView(center: center))
    }
}

extension BackgroundActivityWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        window = nil
    }
}
