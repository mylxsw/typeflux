import AppKit
import TypefluxChatWindowProtocol

/// The child owns only presentation. It cannot construct the application's DI,
/// open conversation databases, invoke tools or upload account state.
@MainActor
public final class ChatWindowPresentation {
    private var session = ChatWindowSession()
    private let offscreen: Bool
    private(set) var window: NSWindow?
    private(set) var text: NSTextView?
    public init(offscreen: Bool = false) { self.offscreen = offscreen }

    public func receive(_ request: ChatWindowEnvelope) throws -> ChatWindowEnvelope {
        let reply = try session.accept(request)
        switch request.kind {
        case .present:
            guard let snapshot = request.snapshot else { throw ChatWindowFailure.invalidProtocol }
            if window == nil { makeWindow() }
            window?.title = snapshot.title
            text?.string = snapshot.messages.map(\.text).joined(separator: "\n\n")
            if offscreen { window?.orderFront(nil) }
            else { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        case .hide, .shutdown: window?.orderOut(nil)
        default: break
        }
        // Even ping reaches here on the main actor, after queued UI work.
        return reply
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: offscreen ? -20000 : 200, y: offscreen ? -20000 : 200, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        window.contentView = scroll
        self.window = window; self.text = text
    }
}
