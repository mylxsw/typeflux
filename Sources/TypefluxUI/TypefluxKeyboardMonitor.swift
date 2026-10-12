import AppKit
import SwiftUI

/// A local monitor tied to this view's window. Removal releases every monitor token.
struct TypefluxKeyboardMonitor: NSViewRepresentable {
    var handle: (NSEvent) -> Bool

    final class MonitorView: NSView {
        var handle: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window,
                      event.window === window, window.attachedSheet == nil else { return event }
                return handle(event) ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.handle = handle
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.stop()
    }
}
