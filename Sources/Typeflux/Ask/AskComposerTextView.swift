import AppKit
import SwiftUI

/// A native editor keeps IME composition, selection and the existing dictation
/// insertion path intact. Return confirms only after marked text is committed.
struct AskComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onDismiss: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = Editor()
        editor.identifier = NSUserInterfaceItemIdentifier("ask.composer")
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 17)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 4, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.onDismiss = onDismiss
        editor.setAccessibilityLabel(placeholder)
        scroll.documentView = editor
        editor.string = text
        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window else { return }
            window.makeFirstResponder(editor)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        editor.onSubmit = onSubmit; editor.onDismiss = onDismiss
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AskComposerTextView
        init(_ parent: AskComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }

    final class Editor: NSTextView {
        var onSubmit: () -> Void = {}
        var onDismiss: () -> Void = {}
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() {
                onSubmit(); return
            }
            if event.keyCode == 53, !hasMarkedText() { onDismiss(); return }
            super.keyDown(with: event)
        }
    }
}
