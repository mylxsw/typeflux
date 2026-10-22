import AppKit
import SwiftUI

/// The one word book window. Translation results open it (⌘B) on the word they show,
/// and `dict word` opens it looking the word up; see `docs/design/word-book-redesign.md`
/// and, for its look, `docs/design/word-book-studio.md`.
@MainActor
final class AskWordBookWindowController: NSObject, NSWindowDelegate {
    static let shared = AskWordBookWindowController()
    static let defaultSize = NSSize(width: 1320, height: 800)
    static let minimumSize = NSSize(width: 720, height: 480)
    // Start the wider three-column layout fresh instead of restoring an old compact frame.
    var frameAutosaveName: NSWindow.FrameAutosaveName = "AskWordBook.v2"

    private var store: (any AskWordBookStoring)?
    private var dictionary: (any AskWordLookingUp)?
    private var modelName: () -> String = { "AI" }
    private var askAI: (@MainActor (String) -> Void)?
    private var settings = SettingsStore()
    private(set) var interfaceStyle: InterfaceStyleObserver?
    private(set) var window: NSWindow?
    private(set) var model: AskWordBookViewModel?

    /// The launcher's word book, the model that writes cards, and how to ask the AI about a
    /// word; `AskConversationWindowController` supplies them.
    func configure(store: any AskWordBookStoring, dictionary: (any AskWordLookingUp)?, settings: SettingsStore,
                   askAI: (@MainActor (String) -> Void)? = nil, modelName: @escaping () -> String) {
        self.store = store
        self.dictionary = dictionary
        self.settings = settings
        if let interfaceStyle { interfaceStyle.refresh() } else {
            interfaceStyle = InterfaceStyleObserver(settings: settings)
        }
        self.askAI = askAI
        self.modelName = modelName
        model?.dictionary = dictionary
        model?.modelName = modelName
        model?.askAI = askAI
    }

    private(set) var presentationTask: Task<Void, Never>?

    deinit { presentationTask?.cancel() }

    /// Opens the window, or brings it forward, showing `key` when it is a word in the book.
    func show(selecting key: String? = nil) {
        if !FeatureProcess.owns(.wordBook) { FeatureProcess.send(.init(destination: .wordBook, action: "showWordBook", payload: Data((key ?? "").utf8))); return }
        guard let model = ensureModel() else { return }
        model.reload()
        presentationTask?.cancel()
        presentationTask = Task { await model.reveal(key) }
        present(model)
    }

    /// Opens the window and looks `text` up in it (`dict word`).
    func show(lookingUp text: String) {
        if !FeatureProcess.owns(.wordBook) { FeatureProcess.send(.init(destination: .wordBook, action: "lookupWord", payload: Data(text.utf8))); return }
        guard let model = ensureModel() else { return }
        model.reload()
        model.lookupText = text
        present(model)
        presentationTask?.cancel()
        presentationTask = Task { await model.lookUp(text) }
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
        window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.wordBook.toolbar")
        window.toolbarStyle = .unified
        let root = AskWordBookView(model: model) { [weak window] in window?.performClose(nil) }
        let content = interfaceStyle.map { AnyView(root.interfaceStyle(following: $0)) } ?? AnyView(root)
        let hosting = TransparentAskHostingView(rootView: content)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = Self.minimumSize
        window.setFrameAutosaveName(frameAutosaveName)
        window.setFrameUsingName(frameAutosaveName)
        if window.frame.width < Self.minimumSize.width { window.setContentSize(Self.defaultSize) }
        if window.frame.origin == .zero { window.center() }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
        self.window = window
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        // AppKit can recalculate content limits when the unified toolbar first attaches.
        window.contentMinSize = Self.minimumSize
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_: Notification) {
        presentationTask?.cancel()
        presentationTask = nil
        model?.reloadTask?.cancel()
        if let window { DockVisibilityController.shared.windowDidHide(window) }
        window = nil
        model = nil
    }
}
