import AppKit
import SwiftUI

/// The one word book window. Translation results open it (⌘B) on the word they show,
/// and `dict word` opens it looking the word up; see `docs/design/word-book-redesign.md`
/// and, for its look, `docs/design/word-book-studio.md`.
@MainActor
final class AskWordBookWindowController: NSObject, NSWindowDelegate {
    static let shared = AskWordBookWindowController()
    static let defaultSize = NSSize(width: 1120, height: 720)
    static let minimumSize = NSSize(width: 900, height: 560)

    private var store: (any AskWordBookStoring)?
    private var dictionary: (any AskWordLookingUp)?
    private var modelName: () -> String = { "AI" }
    private var askAI: (@MainActor (String) -> Void)?
    private var settings = SettingsStore()
    private(set) var window: NSWindow?
    private(set) var model: AskWordBookViewModel?

    /// The launcher's word book, the model that writes cards, and how to ask the AI about a
    /// word; `AskConversationWindowController` supplies them.
    func configure(store: any AskWordBookStoring, dictionary: (any AskWordLookingUp)?, settings: SettingsStore,
                   askAI: (@MainActor (String) -> Void)? = nil, modelName: @escaping () -> String) {
        self.store = store
        self.dictionary = dictionary
        self.settings = settings
        self.askAI = askAI
        self.modelName = modelName
        model?.dictionary = dictionary
        model?.modelName = modelName
        model?.askAI = askAI
    }

    /// Opens the window, or brings it forward, showing `key` when it is a word in the book.
    func show(selecting key: String? = nil) {
        guard let model = ensureModel() else { return }
        model.reload()
        model.reveal(key)
        present(model)
    }

    /// Opens the window and looks `text` up in it (`dict word`).
    func show(lookingUp text: String) {
        guard let model = ensureModel() else { return }
        model.reload()
        model.lookupText = text
        present(model)
        Task { await model.lookUp(text) }
    }

    private func ensureModel() -> AskWordBookViewModel? {
        if let model { return model }
        guard let store else { return nil }
        let model = AskWordBookViewModel(store: store, settings: settings)
        model.dictionary = dictionary
        model.modelName = modelName
        model.askAI = askAI
        self.model = model
        return model
    }

    private func present(_ model: AskWordBookViewModel) {
        if let window {
            DockVisibilityController.shared.windowDidShow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Set up like the main window: a transparent title bar over the view's own backdrop.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = L("ask.wordBook.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let hosting = TransparentAskHostingView(rootView: AskWordBookView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        hosting.sizingOptions = []
        window.contentView = hosting
        window.minSize = Self.minimumSize
        window.setFrameAutosaveName("AskWordBook")
        if window.frame.width < Self.minimumSize.width { window.setContentSize(Self.defaultSize) }
        if window.frame.origin == .zero { window.center() }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_: Notification) {
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        window = nil
        model = nil
    }
}
