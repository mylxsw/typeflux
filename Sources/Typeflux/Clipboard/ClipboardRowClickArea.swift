import AppKit
import SwiftUI

/// Handles left clicks on mouse-down, avoiding SwiftUI's wait for a competing double tap, and
/// drags the entry into other apps once the pointer moves past `ClipboardEntryDrag.threshold`.
/// Context clicks pass through to the row's SwiftUI context menu; scrolling keeps its responder chain.
struct ClipboardRowClickArea: NSViewRepresentable {
    var onClick: (Int) -> Void
    /// Built when a drag starts; empty means the entry cannot be dragged.
    var dragItems: () -> [NSPasteboardWriting] = { [] }
    /// Whether another app accepted the drop.
    var onDragEnded: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> Control {
        let view = Control()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Control, context: Context) {
        view.onClick = onClick
        view.dragItems = dragItems
        view.onDragEnded = onDragEnded
        view.enabled = context.environment.isEnabled
    }

    final class Control: NSView, NSDraggingSource {
        var onClick: (Int) -> Void = { _ in }
        var dragItems: () -> [NSPasteboardWriting] = { [] }
        var onDragEnded: (Bool) -> Void = { _ in }
        var enabled = true
        private var mouseDownLocation: NSPoint?
        private(set) var isDragging = false
        /// Synthetic test events do not set NSApplication.currentEvent.
        var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

        override var acceptsFirstResponder: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled, let event = currentEvent(),
                  event.windowNumber == window?.windowNumber,
                  event.type == .leftMouseDown || event.type == .leftMouseUp,
                  !event.modifierFlags.contains(.control) else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            guard enabled, !event.modifierFlags.contains(.control) else { return }
            mouseDownLocation = event.locationInWindow
            onClick(event.clickCount)
        }

        override func mouseDragged(with event: NSEvent) {
            guard enabled, !isDragging, let start = mouseDownLocation,
                  ClipboardEntryDrag.beginsDrag(from: start, to: event.locationInWindow) else { return }
            let writers = dragItems()
            guard !writers.isEmpty else { return }
            isDragging = true
            let image = snapshot()
            let items = writers.enumerated().map { offset, writer in
                let item = NSDraggingItem(pasteboardWriter: writer)
                // Several files fan out slightly behind the card's image.
                let step = CGFloat(min(offset, 3)) * 6
                item.setDraggingFrame(bounds.offsetBy(dx: step, dy: -step), contents: offset == 0 ? image : nil)
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with _: NSEvent) {
            mouseDownLocation = nil
        }

        func draggingSession(
            _: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            Self.operationMask(for: context)
        }

        func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation: NSDragOperation) {
            finishDrag(operation: operation)
        }

        /// Dropping back onto the panel does nothing; other apps receive a copy.
        static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func finishDrag(operation: NSDragOperation) {
            isDragging = false
            mouseDownLocation = nil
            onDragEnded(operation != [])
        }

        /// The row or card as drawn under this overlay, used as the drag image.
        private func snapshot() -> NSImage? {
            guard let content = window?.contentView, bounds.width > 0, bounds.height > 0 else { return nil }
            let rect = convert(bounds, to: content)
            guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            content.cacheDisplay(in: rect, to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            return image
        }
    }
}
