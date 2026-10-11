import AppKit
import SwiftUI

/// Selectable results can take focus from the composer. Keep Esc on the same
/// launcher navigation path, then return focus to the editor for further typing.
struct AskLauncherEscapeMonitor: NSViewRepresentable {
    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        @discardableResult
        func handle(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window, event.window === window,
                  !(window.firstResponder is AskComposerTextView.Editor),
                  (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                  let content = window.contentView, let editor = Self.editor(in: content),
                  window.makeFirstResponder(editor) else { return false }
            editor.keyDown(with: event)
            return true
        }

        private static func editor(in view: NSView) -> AskComposerTextView.Editor? {
            (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(editor(in:)).first
        }

        override func removeFromSuperview() {
            stop()
            super.removeFromSuperview()
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeNSView(context _: Context) -> MonitorView { MonitorView() }
    func updateNSView(_: MonitorView, context _: Context) {}
    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) { view.stop() }
}
