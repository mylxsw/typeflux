import AppKit
import SwiftUI

/// The target filter never becomes note content or launcher input history, and stores no recent searches.
struct AskNoteCaptureSearchField: NSViewRepresentable {
    @Binding var text: String
    var onSelect: () -> Void
    var onMove: (Int) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = L("ask.noteCapture.search")
        field.stringValue = text
        field.maximumRecents = 0
        field.recentsAutosaveName = nil
        field.setAccessibilityIdentifier("ask.noteCapture.search")
        field.setAccessibilityLabel(L("ask.noteCapture.search"))
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window?.isKeyWindow == true else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: AskNoteCaptureSearchField
        init(_ parent: AskNoteCaptureSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.insertNewline(_:)): parent.onSelect()
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
