import AppKit
import SwiftUI

/// The one word book dialog. Translation results open it (⌘B), on the word they show;
/// see `docs/design/translation-word-book.md` §5.
@MainActor
final class AskWordBookWindowController: NSObject, NSWindowDelegate {
    static let shared = AskWordBookWindowController()

    private var store: (any AskWordBookStoring)?
    private var dictionary: (any AskWordLookingUp)?
    private var modelName: () -> String = { "AI" }
    private var settings = SettingsStore()
    private(set) var window: NSWindow?
    private(set) var model: AskWordBookViewModel?

    /// The launcher's word book and the model that writes cards; `AskConversationWindowController` supplies them.
    func configure(store: any AskWordBookStoring, dictionary: (any AskWordLookingUp)?, settings: SettingsStore,
                   modelName: @escaping () -> String) {
        self.store = store
        self.dictionary = dictionary
        self.settings = settings
        self.modelName = modelName
        model?.dictionary = dictionary
        model?.modelName = modelName
    }

    /// Opens the dialog, or brings it forward, showing `key` when it is a word in the book.
    func show(selecting key: String? = nil) {
        guard let model = ensureModel() else { return }
        model.reload()
        model.reveal(key)
        present(model)
    }

    private func ensureModel() -> AskWordBookViewModel? {
        if let model { return model }
        guard let store else { return nil }
        let model = AskWordBookViewModel(store: store, settings: settings)
        model.dictionary = dictionary
        model.modelName = modelName
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("ask.wordBook.title")
        window.contentView = NSHostingView(rootView: AskWordBookView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        window.minSize = NSSize(width: 940, height: 520)
        window.setFrameAutosaveName("AskWordBook")
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
