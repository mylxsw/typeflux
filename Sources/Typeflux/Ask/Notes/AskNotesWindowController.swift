import AppKit
import SwiftUI

/// The one notes window. AI prompt results open it (⌘B), as do the `nb` keyword
/// and saved-result confirmations; see `docs/design/ai-command-results.md`.
@MainActor
final class AskNotesWindowController: NSObject, NSWindowDelegate {
    static let shared = AskNotesWindowController()
    static let defaultSize = NSSize(width: 1080, height: 700)
    static let minimumSize = NSSize(width: 860, height: 520)

    private(set) var store: (any AskNoteStoring)?
    private var askAI: (@MainActor (String) -> Void)?
    private var appearance: () -> NSAppearance? = { nil }
    private(set) var window: NSWindow?
    private(set) var model: AskNotesViewModel?

    /// The notes and how to ask the AI about one; `AskConversationWindowController` supplies them.
    func configure(store: any AskNoteStoring, askAI: (@MainActor (String) -> Void)?,
                   appearance: @escaping () -> NSAppearance?) {
        self.store = store
        self.askAI = askAI
        self.appearance = appearance
        model?.askAI = askAI
    }

    /// Opens the window, or brings it forward, showing `id` when it is a note.
    func show(selecting id: UUID? = nil) {
        guard let model = ensureModel() else { return }
        model.reload()
        model.reveal(id)
        present(model)
    }

    private func ensureModel() -> AskNotesViewModel? {
        if let model { return model }
        guard let store else { return nil }
        let model = AskNotesViewModel(store: store)
        model.askAI = askAI
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = L("ask.notes.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let hosting = TransparentAskHostingView(rootView: AskNotesView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        hosting.sizingOptions = []
        window.contentView = hosting
        window.minSize = Self.minimumSize
        window.setFrameAutosaveName("AskNotes")
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

    func windowWillClose(_: Notification) {
        model?.finishEditing()
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        window = nil
        model = nil
    }
}
