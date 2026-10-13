import AppKit
import SwiftUI

/// Delivers ↑ and ↓ to `onMove` while it is in the window, before the focused
/// text field turns them into caret moves. `onKeyPress` needs macOS 14.
struct AskArrowKeyMonitor: NSViewRepresentable {
    var onMove: (Int) -> Void

    static let upKeyCode: UInt16 = 126
    static let downKeyCode: UInt16 = 125

    /// The highlight step for a key, or nil when the key is not an arrow.
    static func delta(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return nil }
        switch keyCode {
        case upKeyCode: return -1
        case downKeyCode: return 1
        default: return nil
        }
    }

    final class MonitorView: NSView {
        var onMove: (Int) -> Void = { _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      let delta = AskArrowKeyMonitor.delta(keyCode: event.keyCode, modifiers: event.modifierFlags)
                else { return event }
                self.onMove(delta)
                return nil
            }
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.onMove = onMove
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.removeFromSuperview()
    }
}
