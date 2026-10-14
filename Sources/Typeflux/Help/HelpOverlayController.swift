import AppKit
import SwiftUI

/// Shows the usage guide over the whole screen under the pointer, menu bar and Dock included.
/// The panel takes keyboard focus without activating Typeflux, like the launcher, so closing
/// it leaves the user in the app they were using.
@MainActor
final class HelpOverlayController {
    let model: HelpOverlayModel
    private let settingsStore: SettingsStore
    private var panel: HelpOverlayWindow?
    private var hostingView: NSHostingView<AnyView>?
    private lazy var interfaceStyleObserver = InterfaceStyleObserver(settings: settingsStore)
    private var keyMonitor: Any?
    private var keyObserver: NSObjectProtocol?

    /// Above the menu bar so the scrim covers it, below system alerts and the screen saver.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    init(settingsStore: SettingsStore, model: HelpOverlayModel) {
        self.settingsStore = settingsStore
        self.model = model
    }

    var isPresented: Bool { panel?.isVisible == true }
    var presentedWindow: NSWindow? { isPresented ? panel : nil }

    func show(query: String) {
        model.prepare(query: query)
        let panel = panel ?? makePanel()
        applyAppearance(to: panel)
        if let screen = Self.screenUnderPointer() {
            panel.setFrame(screen.frame, display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func dismiss() {
        guard let panel else { return }
        removeMonitor()
        panel.orderOut(nil)
        model.dismissed()
    }

    static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Window

    private func makePanel() -> HelpOverlayWindow {
        let frame = Self.screenUnderPointer()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = HelpOverlayWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.level = Self.level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.help")
        let rootView = AnyView(HelpOverlayView(model: model).interfaceStyle(following: interfaceStyleObserver))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Back from System Settings: a permission may have been granted meanwhile.
            MainActor.assumeIsolated { self?.model.reloadPermissions() }
        }
        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    private func applyAppearance(to panel: NSPanel) {
        switch settingsStore.appearanceMode {
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        default: panel.appearance = nil
        }
    }

    // MARK: - Keys

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Keys the guide owns; everything else goes to the search field.
    func handle(_ event: NSEvent) -> Bool {
        // While an input method is composing, its own keys (Return, Esc, arrows) belong to it.
        if (panel?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        if let key = Self.key(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                              command: command) {
            return model.handle(key)
        }
        // Typing anywhere in the guide searches, even after a click took focus from the field.
        if !command, !flags.contains(.control), let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
           !(panel?.firstResponder is NSText) {
            model.query += characters
            model.handle(.find)
            return true
        }
        return false
    }

    static func key(keyCode: UInt16, characters: String, command: Bool) -> HelpOverlayModel.Key? {
        switch keyCode {
        case 53: return .escape
        case 126: return .up
        case 125: return .down
        case 36, 76: return command ? .commandEnter : .enter
        default: break
        }
        guard command else { return nil }
        if characters.lowercased() == "f" { return .find }
        if let number = Int(characters), (1 ... HelpPage.allCases.count).contains(number) { return .page(number) }
        return nil
    }
}

/// A borderless panel that can still take the keyboard for the search field.
final class HelpOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
