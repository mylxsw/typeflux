import AppKit
import SwiftUI

/// Native mouse handling keeps screen coordinates stable while the toolbar's window moves.
struct ScreenRecordingToolbarDragArea: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> ScreenRecordingToolbarDragView {
        ScreenRecordingToolbarDragView()
    }

    func updateNSView(_ view: ScreenRecordingToolbarDragView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier("recording.toolbar.drag")
    }
}

@MainActor
final class ScreenRecordingToolbarDragView: NSView {
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    private var dragStart: (pointer: CGPoint, origin: CGPoint)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (pointerLocation(), window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        let pointer = pointerLocation()
        window.setFrameOrigin(CGPoint(
            x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
            y: dragStart.origin.y + pointer.y - dragStart.pointer.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
