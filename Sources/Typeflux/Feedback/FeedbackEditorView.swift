import AppKit
import SwiftUI

/// What the toolbar shows as active, following the selection in the editor.
@MainActor
final class FeedbackToolbarState: ObservableObject {
    @Published var bold = false
    @Published var italic = false
    @Published var strikethrough = false
    @Published var block: FeedbackBlockFormat?
}

/// The rich text editor of the feedback body.
struct FeedbackEditorView: NSViewRepresentable {
    let model: FeedbackWindowModel
    let toolbar: FeedbackToolbarState

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, toolbar: toolbar)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = FeedbackTextView()
        textView.delegate = context.coordinator
        textView.placeholder = L("feedback.direct.contentPlaceholder")
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude
        )
        textView.onFiles = { [weak model] urls in model?.addFiles(urls) }
        textView.onImageData = { [weak model] data in
            model?.addImageData(data, filename: Self.screenshotName())
        }
        textView.onLinkRequest = { [weak textView] in
            guard let textView else { return }
            Self.promptForLink(in: textView)
        }
        scrollView.documentView = textView
        model.editor.textView = textView
        context.coordinator.textView = textView

        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_: NSScrollView, context _: Context) {}

    static func screenshotName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "screenshot-\(formatter.string(from: Date())).png"
    }

    /// Asks for a link target and applies it to the selection; only http and https are accepted.
    @MainActor
    static func promptForLink(in textView: FeedbackTextView) {
        guard textView.selectedRange().length > 0 else { return }
        let alert = NSAlert()
        alert.messageText = L("feedback.editor.link.title")
        alert.informativeText = L("feedback.editor.link.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field removes the link.
        textView.applyLink(text.isEmpty ? nil : FeedbackRichText.normalizedLinkURL(text))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: FeedbackWindowModel
        let toolbar: FeedbackToolbarState
        weak var textView: FeedbackTextView?

        init(model: FeedbackWindowModel, toolbar: FeedbackToolbarState) {
            self.model = model
            self.toolbar = toolbar
        }

        func textDidChange(_: Notification) {
            model.editorDidChange()
        }

        func textViewDidChangeSelection(_: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            if range.length > 0 {
                toolbar.bold = textView.isInlineFormatApplied(.bold, in: range)
                toolbar.italic = textView.isInlineFormatApplied(.italic, in: range)
                toolbar.strikethrough = textView.isInlineFormatApplied(.strikethrough, in: range)
            } else {
                let font = textView.typingAttributes[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                toolbar.bold = traits.contains(.boldFontMask)
                toolbar.italic = traits.contains(.italicFontMask)
                toolbar.strikethrough = textView.typingAttributes[.strikethroughStyle] != nil
            }
            toolbar.block = textView.currentBlockFormat
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn range: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let view = textView as? FeedbackTextView, let replacementString else { return true }
            return !view.applyMarkdownShortcut(replacingRange: range, replacement: replacementString)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)),
                  let view = textView as? FeedbackTextView else { return false }
            return view.handleNewline()
        }

        /// Clicks on an attachment block: the remove button removes it, a failed block retries.
        func textView(
            _ textView: NSTextView,
            clickedOn _: NSTextAttachmentCellProtocol,
            in cellFrame: NSRect,
            at charIndex: Int
        ) {
            guard let attachment = textView.textStorage?.attribute(.attachment, at: charIndex, effectiveRange: nil)
                as? FeedbackTextAttachment else { return }
            let frame = cellFrame.insetBy(dx: 0, dy: 4)
            let click = textView.convert(textView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            if FeedbackAttachmentCell.removeButtonRect(in: frame).insetBy(dx: -4, dy: -4).contains(click) {
                model.remove(id: attachment.attachmentID)
            } else if case .failed = model.attachment(id: attachment.attachmentID)?.state {
                model.retry(id: attachment.attachmentID)
            }
        }

        func textView(
            _ textView: NSTextView,
            doubleClickedOn _: NSTextAttachmentCellProtocol,
            in _: NSRect,
            at charIndex: Int
        ) {
            guard let attachment = textView.textStorage?.attribute(.attachment, at: charIndex, effectiveRange: nil)
                as? FeedbackTextAttachment,
                let url = model.previewURL(id: attachment.attachmentID) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
