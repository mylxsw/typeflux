import AppKit
import SwiftUI

/// A native editor keeps IME composition, selection and the existing dictation
/// insertion path intact. Return confirms only after marked text is committed.
struct AskComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    var placeholder: String
    var onSubmit: () -> Void
    var onDismiss: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = Editor()
        editor.identifier = NSUserInterfaceItemIdentifier("ask.composer")
        editor.isRichText = false
        editor.isEditable = isEnabled
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: StudioTheme.Typography.bodyLarge)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.onDismiss = onDismiss
        editor.onHeightChange = onHeightChange
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
        editor.isEditable = isEnabled
        editor.onSubmit = onSubmit; editor.onDismiss = onDismiss
        editor.onHeightChange = onHeightChange
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editor.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AskComposerTextView
        init(_ parent: AskComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            (editor as? Editor)?.reportHeight()
        }
    }

    final class Editor: NSTextView {
        var onSubmit: () -> Void = {}
        var onDismiss: () -> Void = {}
        var onHeightChange: (CGFloat) -> Void = { _ in }
        private var reportedHeight: CGFloat = 0
        override func layout() { super.layout(); reportHeight() }
        func reportHeight() {
            guard let layoutManager, let textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let height = min(148, max(32, ceil(layoutManager.usedRect(for: textContainer).height + 12)))
            guard height != reportedHeight else { return }
            reportedHeight = height
            DispatchQueue.main.async { [weak self] in self?.onHeightChange(height) }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() {
                onSubmit(); return
            }
            if event.keyCode == 53, !hasMarkedText() { onDismiss(); return }
            super.keyDown(with: event)
        }
    }
}
