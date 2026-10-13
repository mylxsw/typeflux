import AppKit
import SwiftUI

/// The one notes window. AI prompt results open it (⌘B), as do the `nb` keyword,
/// saved-result confirmations and the menu bar; see `docs/design/notebook-redesign.md`.
/// Uses library template B in `docs/design/ui-system.md`.
@MainActor
final class AskNotesWindowController: NSObject, NSWindowDelegate {
    static let shared = AskNotesWindowController()
    static let defaultSize = NSSize(width: 1320, height: 800)
    static let minimumSize = NSSize(width: 680, height: 500)
    var frameAutosaveName: NSWindow.FrameAutosaveName = "AskNotes.v2"

    private(set) var store: (any AskNoteStoring)?
    private var askAI: (@MainActor (AskNote) -> Void)?
    private var openConversation: (@MainActor (String) -> Void)?
    private var appearance: () -> NSAppearance? = { nil }
    private var interfaceStyle: InterfaceStyleObserver?
    private var settings: SettingsStore?
    private(set) var window: NSWindow?
    private(set) var model: AskNotesViewModel?

    /// The notes and what the window can hand back to the conversation window;
    /// `AskConversationWindowController` supplies them.
    func configure(store: any AskNoteStoring, settings: SettingsStore? = nil, askAI: (@MainActor (AskNote) -> Void)?,
                   openConversation: (@MainActor (String) -> Void)? = nil,
                   appearance: @escaping () -> NSAppearance?) {
        self.store = store
        self.askAI = askAI
        self.openConversation = openConversation
        self.appearance = appearance
        self.settings = settings
        if let settings { interfaceStyle = InterfaceStyleObserver(settings: settings) }
        model?.agentSettings = settings
        model?.askAI = askAI
        model?.openConversation = openConversation
    }

    /// Opens the window, or brings it forward, showing `id` when it is a note.
    func show(selecting id: UUID? = nil) {
        guard let model = ensureModel() else { return }
        model.reload()
        model.reveal(id)
        present(model)
    }

    /// Opens the window on a new note with this title, ready to write.
    func showNewNote(title: String = "") {
        guard let model = ensureModel() else { return }
        model.reload()
        model.createNote(title: title)
        present(model)
    }

    private func ensureModel() -> AskNotesViewModel? {
        if let model { return model }
        guard let store else { return nil }
        let model = AskNotesViewModel(store: store)
        model.askAI = askAI
        model.openConversation = openConversation
        model.agentSettings = settings
        self.model = model
        return model
    }

    private func present(_ model: AskNotesViewModel) {
        if let window {
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Native split-view chrome supplies the sidebar material; content remains solid.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.title = L("ask.notes.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // SwiftUI installs the title, grouped actions and native toolbar search.
        window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.notes.toolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.notes")
        let root = AskNotesView(model: model) { [weak window] in window?.performClose(nil) }
        let content = interfaceStyle.map { AnyView(root.interfaceStyle(following: $0)) } ?? AnyView(root)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = Self.minimumSize
        window.setFrameAutosaveName(frameAutosaveName)
        if window.frame.width < Self.minimumSize.width { window.setContentSize(Self.defaultSize) }
        if window.frame.origin == .zero { window.center() }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = appearance()
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        model?.finishEditing() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        let saved = model?.finishEditing() ?? true
        window = nil
        // Tear down window-scoped menus, shortcuts and observers even if AppKit retains the closed window.
        closed.contentView = nil
        closed.toolbar = nil
        DockVisibilityController.shared.windowDidHide(closed)
        // A direct programmatic close bypasses windowShouldClose. Keep a failed
        // draft in memory so showing the window again still recovers it.
        if saved { model = nil }
    }
}
