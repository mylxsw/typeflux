import AppKit
import SwiftUI

/// Handles left clicks on mouse-down, avoiding SwiftUI's wait for a competing double tap.
/// Context clicks pass through to the row's SwiftUI context menu; scrolling keeps its responder chain.
struct ClipboardRowClickArea: NSViewRepresentable {
    var onClick: (Int) -> Void

    func makeNSView(context: Context) -> Control {
        let view = Control()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Control, context: Context) {
        view.onClick = onClick
        view.enabled = context.environment.isEnabled
    }

    final class Control: NSView {
        var onClick: (Int) -> Void = { _ in }
        var enabled = true
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
            onClick(event.clickCount)
        }

        override func mouseUp(with _: NSEvent) {}
    }
}
