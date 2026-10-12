import AppKit
import SwiftUI

/// NSSearchField supplies editing, the clear button, VoiceOver and input method support.
struct TypefluxNativeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var prompt: String
    var identifier: String
    var borderless = false
    var onEscape: () -> Void = {}

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TypefluxNativeSearchField
        init(_ parent: TypefluxNativeSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_: Notification) {
            parent.focused = true
        }

        func controlTextDidEndEditing(_: Notification) {
            parent.focused = false
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)),
                  !textView.hasMarkedText() else { return false }
            parent.onEscape()
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context _: Context) -> CGSize? {
        // A taller capsule centers the native control; stretching its cell can
        // overlap the magnifier and placeholder on macOS 26.
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: max(22, nsView.intrinsicContentSize.height))
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.stringValue = text
        field.isEnabled = context.environment.isEnabled
        field.controlSize = context.environment.controlSize == .small ? .small : .regular
        configure(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        field.isEnabled = context.environment.isEnabled
        field.controlSize = context.environment.controlSize == .small ? .small : .regular
        if field.stringValue != text {
            field.stringValue = text
        }
        // Focus changes run after insertion; they never activate another window.
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak field, weak coordinator] in
            guard let field, let coordinator, let window = field.window,
                  window.isKeyWindow, window.attachedSheet == nil, field.isEnabled else { return }
            if coordinator.parent.focused, field.currentEditor() == nil {
                window.makeFirstResponder(field)
            } else if !coordinator.parent.focused, field.currentEditor() != nil {
                window.makeFirstResponder(nil)
            }
        }
    }

    private func configure(_ field: NSSearchField) {
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.setAccessibilityIdentifier(identifier)
        field.isBezeled = !borderless
        field.drawsBackground = !borderless
        if let cell = field.cell as? NSSearchFieldCell {
            if borderless {
                cell.searchButtonCell = nil
            } else if cell.searchButtonCell == nil {
                cell.resetSearchButtonCell()
            }
        }
        field.font = NSFont.preferredFont(forTextStyle: .body)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator _: Coordinator) {
        field.delegate = nil
    }
}
