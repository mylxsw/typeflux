import AppKit
import SwiftUI

private final class TransparentAboutHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

@MainActor
final class AboutWindowController: NSObject {
    static let shared = AboutWindowController()

    private let settingsStore = SettingsStore()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private lazy var interfaceStyleObserver = InterfaceStyleObserver(settings: settingsStore)
    private var languageObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?

    override init() {
        super.init()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                self.hostingView?.rootView = self.rootView()
                window.title = L("window.about")
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                self.hostingView?.rootView = self.rootView()
                self.applyAppearance(to: window)
            }
        }
    }

    func show() {
        AppLocalization.shared.setLanguage(settingsStore.appLanguage)
        let rootView = rootView()

        if let window {
            hostingView?.rootView = rootView
            applyAppearance(to: window)
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = TransparentAboutHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("window.about")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 560)
        applyAppearance(to: window)

        hostingView = hosting
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)
    }

    private func rootView() -> AnyView {
        AnyView(AboutView(appearanceMode: settingsStore.appearanceMode).interfaceStyle(following: interfaceStyleObserver))
    }
}

extension AboutWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
        }
        window = nil
        hostingView = nil
    }
}
