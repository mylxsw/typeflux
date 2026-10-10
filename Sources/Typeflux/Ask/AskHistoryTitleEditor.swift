import AppKit
import SwiftUI

/// A single-line native editor preserves selection and Chinese input methods.
/// Return or blur saves once; Escape discards the draft without a dialog.
struct AskHistoryTitleEditor: NSViewRepresentable {
    let title: String
    var selected: Bool
    var onFinish: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeNSView(context: Context) -> Field {
        let field = Field(string: title)
        field.delegate = context.coordinator
        field.identifier = .init("ask.history.title")
        field.setAccessibilityLabel(L("ask.title.rename"))
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.onFinish = onFinish
        field.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        field.textColor = .labelColor
        // Never replace the live field editor: it may contain marked IME text.
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.stopMonitoringClicks()
    }

    final class Field: NSTextField {
        private var focusedOnce = false
        private var clickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoringClicks()
            guard window != nil, !focusedOnce else { return }
            // SwiftUI buttons do not always take keyboard focus. End editing
            // before delivering an outside click, so its original action still runs.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.currentEditor() != nil else { return event }
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, !self.focusedOnce else { return }
                if window.makeFirstResponder(self) {
                    self.focusedOnce = true
                    // selectText(_:) would begin another field-editing session
                    // and emit an end-edit notification for this one.
                    (self.currentEditor() as? NSTextView)?.setSelectedRange(
                        NSRange(location: 0, length: self.stringValue.utf16.count))
                }
            }
        }

        func stopMonitoringClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onFinish: (String?) -> Void
        private var finished = false

        init(onFinish: @escaping (String?) -> Void) { self.onFinish = onFinish }

        private func finish(_ title: String?) {
            guard !finished else { return }
            finished = true
            onFinish(title)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                finish(textView.string)
            case #selector(NSResponder.cancelOperation(_:)):
                finish(nil)
            default:
                return false
            }
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
