import AppKit
import SwiftUI

/// Both terminal hosts mount this field when the foreground command finishes.
struct TerminalPromptField: NSViewRepresentable {
    let model: TerminalLauncherModel
    let placeholder: String
    let focusRequest: Int
    let submit: () -> Void

    func makeNSView(context: Context) -> Field {
        let field = Field(string: model.text)
        field.model = model
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(L("terminal.command.placeholder"))
        field.delegate = field
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        field.model = model
        field.submit = submit
        field.placeholderString = placeholder
        if field.stringValue != model.text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = model.text
        }
        if field.focusRequest != focusRequest {
            field.focusRequest = focusRequest
            field.requestFocus()
        }
    }

    final class Field: NSTextField, NSTextFieldDelegate {
        weak var model: TerminalLauncherModel?
        var submit: (() -> Void)?
        var focusRequest = 0
        private let mountFocus = MountedEditorFocus()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocus()
        }

        func requestFocus() {
            mountFocus.request(self) { [weak self] in
                guard let model = self?.model else { return false }
                return model.prompt != .running
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            model?.resetCompletion()
            model?.text = stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(insertNewline(_:)), !textView.hasMarkedText() else { return false }
            submit?()
            return true
        }
    }
}
