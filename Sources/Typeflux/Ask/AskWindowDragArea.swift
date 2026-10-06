import AppKit
import SwiftUI

/// What the launcher's drag areas ask of the window controller: where the panel
/// may go while dragged, what to do once it is let go, and a double-click to
/// put it back in the middle.
struct AskWindowDragHandlers {
    var move: (NSPoint) -> NSPoint = { $0 }
    var end: () -> Void = {}
    var reset: () -> Void = {}
}

private struct AskWindowDragKey: EnvironmentKey {
    static let defaultValue: AskWindowDragHandlers? = nil
}

extension EnvironmentValues {
    /// Set by the launcher only; its bottom bar's empty space then moves the panel.
    var askWindowDrag: AskWindowDragHandlers? {
        get { self[AskWindowDragKey.self] }
        set { self[AskWindowDragKey.self] = newValue }
    }
}

/// Empty space that moves its window when dragged. Only these areas move the
/// launcher: being movable by its whole background would take drags meant for
/// the editor and the result text.
struct AskWindowDragArea: NSViewRepresentable {
    var handlers: AskWindowDragHandlers

    func makeNSView(context _: Context) -> AskWindowDragView {
        let view = AskWindowDragView()
        view.handlers = handlers
        return view
    }

    func updateNSView(_ view: AskWindowDragView, context _: Context) {
        view.handlers = handlers
    }
}

final class AskWindowDragView: NSView {
    var handlers = AskWindowDragHandlers()
    /// Where the pointer is on screen; tests move it themselves.
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var start: (mouse: NSPoint, origin: NSPoint)?
    private var moved = false

    override var mouseDownCanMoveWindow: Bool { false }
    /// The launcher never activates the app, so the first click must already drag.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            start = nil
            handlers.reset()
            return
        }
        guard let window else { return }
        start = (mouseLocation(), window.frame.origin)
        moved = false
    }

    override func mouseDragged(with _: NSEvent) {
        guard let window, let start else { return }
        let mouse = mouseLocation()
        let proposed = NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        if !moved { NSCursor.closedHand.set() }
        moved = true
        window.setFrameOrigin(handlers.move(proposed))
    }

    override func mouseUp(with _: NSEvent) {
        defer { start = nil; moved = false }
        guard start != nil, moved else { return }
        window?.invalidateCursorRects(for: self)
        handlers.end()
    }
}
