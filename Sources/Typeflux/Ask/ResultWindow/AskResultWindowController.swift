import AppKit
import Combine
import SwiftUI

/// The result windows: one per ⌘O (or opened note), cascading from the last one, each
/// remembering the size the user last gave a result window.
@MainActor
final class AskResultWindowController: NSObject, NSWindowDelegate {
    static let shared = AskResultWindowController()
    static let defaultSize = NSSize(width: 560, height: 640)
    static let minimumSize = NSSize(width: 420, height: 360)
    static let sizeKey = "AskResultWindowSize"

    /// What every new window's document can do; `AskConversationWindowController` supplies it.
    var services = AskResultDocument.Services()
    var appearance: () -> NSAppearance? = { nil }
    var defaults: UserDefaults = .standard

    private struct Entry {
        var window: NSWindow
        var document: AskResultDocument
        var pinning: AnyCancellable
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var notesObserver: NSObjectProtocol?

    var documents: [AskResultDocument] { entries.values.map(\.document) }

    override init() {
        super.init()
        notesObserver = NotificationCenter.default.addObserver(forName: .askNotesDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.documents.forEach { $0.refreshNote() } }
        }
    }

    /// A saved note, to read beside other windows.
    @discardableResult
    func open(_ note: AskNote) -> AskResultDocument {
        if let shown = documents.first(where: { $0.fromNote && $0.noteID == note.id }),
           let entry = entries.values.first(where: { $0.document === shown }) {
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return shown
        }
        let document = AskResultDocument(note: note, services: services)
        present(document)
        return document
    }

    func present(_ document: AskResultDocument) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: savedSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = document.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let hosting = TransparentAskHostingView(rootView: AskResultWindowView(document: document) { [weak window] in
            window?.performClose(nil)
        })
        hosting.sizingOptions = []
        window.contentView = hosting
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = appearance()
        if let last = entries.values.map(\.window).min(by: { $0.orderedIndex < $1.orderedIndex }) {
            let topLeft = NSPoint(x: last.frame.minX, y: last.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else {
            window.center()
        }
        let pinning = document.$pinned.sink { [weak window] pinned in window?.level = pinned ? .floating : .normal }
        entries[ObjectIdentifier(window)] = Entry(window: window, document: document, pinning: pinning)
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var savedSize: NSSize {
        guard let stored = defaults.string(forKey: Self.sizeKey) else { return Self.defaultSize }
        let size = NSSizeFromString(stored)
        return NSSize(width: max(Self.minimumSize.width, size.width), height: max(Self.minimumSize.height, size.height))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        defaults.set(NSStringFromSize(window.frame.size), forKey: Self.sizeKey)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.document.close()
        DockVisibilityController.shared.windowDidHide(window)
    }
}
