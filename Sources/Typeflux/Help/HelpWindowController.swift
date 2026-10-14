import AppKit
import SwiftUI

/// The usage guide's window: a normal app window like the notebook, with traffic lights,
/// resizable, remembering its frame, following the interface style and the appearance.
@MainActor
final class HelpWindowController: NSObject, NSWindowDelegate {
    let model: HelpGuideModel
    private let settingsStore: SettingsStore
    private(set) var window: NSWindow?
    private lazy var interfaceStyleObserver = InterfaceStyleObserver(settings: settingsStore)
    private var keyMonitor: Any?
    private var keyObserver: NSObjectProtocol?

    static let frameAutosaveName = "HelpGuide.v1"

    init(settingsStore: SettingsStore, model: HelpGuideModel) {
        self.settingsStore = settingsStore
        self.model = model
    }

    var isPresented: Bool { window?.isVisible == true }
    var presentedWindow: NSWindow? { isPresented ? window : nil }

    /// Opens the window, or brings it forward, searching for `query` when it is not empty.
    func show(query: String) {
        model.prepare(query: query)
        let window = window ?? makeWindow()
        applyAppearance(to: window)
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitor()
    }

    func dismiss() {
        window?.performClose(nil)
    }

    func windowWillClose(_: Notification) {
        removeMonitor()
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        model.dismissed()
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: HelpWindowView.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Translucent like the notebook window, so Liquid Glass shows the desktop behind it.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = L("help.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the title bar the 52pt height of the other windows.
        window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.help.toolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.help")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = HelpWindowView(model: model).interfaceStyle(following: interfaceStyleObserver)
        let hosting = TransparentAskHostingView(rootView: AnyView(root))
        // The hosting view keeps the window's minimum in step with the view's minimum frame.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if window.frame.width < HelpWindowView.minimumSize.width {
            window.setContentSize(HelpWindowView.defaultSize)
        }
        if window.frame.origin == .zero { window.center() }
        window.contentMinSize = HelpWindowView.minimumSize
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            // Back from System Settings: a permission may have been granted meanwhile.
            MainActor.assumeIsolated { self?.model.reloadPermissions() }
        }
        self.window = window
        return window
    }

    private func applyAppearance(to window: NSWindow) {
        switch settingsStore.appearanceMode {
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
    }

    // MARK: - Keys

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
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
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        if let key = Self.key(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                              command: command) {
            return model.handle(key)
        }
        // Typing anywhere in the guide searches, even after a click took focus from the field.
        if !command, !flags.contains(.control), let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
           !(window?.firstResponder is NSText) {
            model.query += characters
            model.handle(.find)
            return true
        }
        return false
    }

    static func key(keyCode: UInt16, characters: String, command: Bool) -> HelpGuideModel.Key? {
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
