import AppKit
import SwiftUI

/// Captures a file row's context click while ordinary clicks and scrolling
/// still reach its SwiftUI button. The editor keeps keyboard focus.
struct AskQuickResultSecondaryClick: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> Control {
        let view = Control()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: Control, context: Context) {
        nsView.onClick = onClick
        nsView.enabled = context.environment.isEnabled
    }

    final class Control: NSView {
        var onClick: () -> Void = {}
        var enabled = true
        /// Synthetic events in command-line tests do not set NSApplication.currentEvent.
        var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled, let event = currentEvent(),
                  event.windowNumber == window?.windowNumber else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            if enabled { onClick() }
        }

        override func mouseDown(with event: NSEvent) {
            if enabled, event.modifierFlags.contains(.control) { onClick() }
        }
    }
}
