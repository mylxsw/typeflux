import AppKit
import SwiftUI

/// The one notes window. AI prompt results open it (⌘B), as do the `nb` keyword,
/// saved-result confirmations and the menu bar; see `docs/design/notebook-redesign.md`.
/// It is built like the conversation window and follows the same interface style.
@MainActor
final class AskNotesWindowController: NSObject, NSWindowDelegate {
    static let shared = AskNotesWindowController()
    static let defaultSize = NSSize(width: 1320, height: 800)
    static let minimumSize = NSSize(width: 680, height: 500)

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
        if !FeatureProcess.owns(.notes) { FeatureProcess.send(.init(destination: .notes, action: "showNotes", payload: Data((id?.uuidString ?? "").utf8))); return }
        guard let model = ensureModel() else { return }
        model.perform {
            await model.reload().value
            await model.reveal(id)
        }
        present(model)
    }

    /// Opens the window on a new note with this title, ready to write.
    func showNewNote(title: String = "") {
        if !FeatureProcess.owns(.notes) { FeatureProcess.send(.init(destination: .notes, action: "newNote", payload: Data(title.utf8))); return }
        guard let model = ensureModel() else { return }
        model.perform {
            await model.reload().value
            await model.createNote(title: title)
        }
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
        // Translucent like the conversation window, so both share the same backdrop.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = L("ask.notes.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the title bar the conversation window's 52pt
        // height, so the traffic lights line up with the in-window title rows.
        window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.notes.toolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.notes")
        let root = AskNotesView(model: model) { [weak window] in window?.performClose(nil) }
        let content = interfaceStyle.map { AnyView(root.interfaceStyle(following: $0)) }
            ?? AnyView(root.scrollIndicators(.never))
        let hosting = TransparentAskHostingView(rootView: content)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = Self.minimumSize
        window.setFrameAutosaveName("AskNotes.v2")
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

    private var closing = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing || model == nil { return true }
        guard let model else { return true }
        model.perform { [weak self, weak sender] in
            guard await model.finishEditing(), let self, let sender, self.window === sender else { return }
            self.closing = true
            sender.performClose(nil)
            self.closing = false
        }
        return false
    }

    func windowWillClose(_: Notification) {
        model?.cancelPendingReads()
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        window = nil
        // Direct close cannot await the save barrier. Retain the model and its draft for reopening.
        if model?.hasUnsavedDraft == false, model?.pendingTitle == nil { model = nil }
    }
}
