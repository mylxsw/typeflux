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
        field.onOutsideClick = { [weak field, weak coordinator = context.coordinator] in
            guard let field else { return }
            coordinator?.finish(field.currentEditor()?.string ?? field.stringValue, field: field)
        }
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
        field.isFinished = true
        field.stopMonitoringClicks()
    }

    final class Field: NSTextField {
        var hasUserInteracted = false
        var isFinished = false
        var onOutsideClick: () -> Void = {}
        private var selectedInitialTitle = false
        private var focusScheduled = false
        private var clickMonitor: Any?
        private var resignObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoringClicks()
            guard let window, !isFinished else { return }
            // SwiftUI buttons do not always take keyboard focus. End editing
            // before delivering an outside click, so its original action still runs.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isFinished else { return event }
                if event.type == .keyDown {
                    if self.currentEditor() != nil { self.hasUserInteracted = true }
                } else if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.hasUserInteracted = true
                } else if self.selectedInitialTitle || self.hasUserInteracted {
                    self.onOutsideClick()
                    if self.currentEditor() != nil { window.makeFirstResponder(nil) }
                }
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                self?.onOutsideClick()
            }
            requestInitialFocus()
        }

        func requestInitialFocus() {
            guard window != nil, !isFinished, !hasUserInteracted, !focusScheduled else { return }
            focusScheduled = true
            // Main-queue blocks also run inside native menu tracking. Default
            // run-loop mode waits until menu dismissal has handed focus back.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard let window = self.window, window.isKeyWindow,
                      !self.isFinished, !self.hasUserInteracted else { return }
                if window.makeFirstResponder(self), !self.selectedInitialTitle {
                    self.selectedInitialTitle = true
                    (self.currentEditor() as? NSTextView)?.setSelectedRange(
                        NSRange(location: 0, length: self.stringValue.utf16.count))
                }
            }
        }

        func stopMonitoringClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onFinish: (String?) -> Void
        private var finished = false

        init(onFinish: @escaping (String?) -> Void) { self.onFinish = onFinish }

        func finish(_ title: String?, field: Field?) {
            guard !finished else { return }
            finished = true
            field?.isFinished = true
            onFinish(title)
        }

        func controlTextDidChange(_ notification: Notification) {
            (notification.object as? Field)?.hasUserInteracted = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? Field, !finished else { return }
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            if field.hasUserInteracted || movement == NSReturnTextMovement || movement == NSTabTextMovement {
                finish(field.stringValue, field: field)
            } else {
                // Closing a context menu can restore the previous responder.
                // Keep an untouched rename open through that system handoff.
                field.requestInitialFocus()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                finish(textView.string, field: control as? Field)
            case #selector(NSResponder.cancelOperation(_:)):
                finish(nil, field: control as? Field)
            default:
                return false
            }
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
