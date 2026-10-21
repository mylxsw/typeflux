import AppKit
import SwiftUI

/// What the toolbar shows as active, following the selection in the editor.
@MainActor
final class FeedbackToolbarState: ObservableObject {
    @Published var bold = false
    @Published var italic = false
    @Published var strikethrough = false
    @Published var block: FeedbackBlockFormat?
    /// The link popover under the toolbar's link button (also opened with ⌘K).
    @Published var isLinkEntryPresented = false

    /// Opens the link entry when text is selected; a link needs text to sit on.
    func requestLinkEntry(in textView: FeedbackTextView?) {
        guard let textView, textView.selectedRange().length > 0 else { return }
        isLinkEntryPresented = true
    }
}

/// The rich text editor of the feedback body.
struct FeedbackEditorView: NSViewRepresentable {
    let model: FeedbackWindowModel
    let toolbar: FeedbackToolbarState

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, toolbar: toolbar)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TFOverlayScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

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
        textView.onLinkRequest = { [weak textView, weak toolbar] in
            toolbar?.requestLinkEntry(in: textView)
        }
        textView.onRemoveAttachment = { [weak model] id in model?.remove(id: id) }
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: FeedbackWindowModel
        let toolbar: FeedbackToolbarState
        private let openFile: (URL) -> Void
        weak var textView: FeedbackTextView?

        init(
            model: FeedbackWindowModel,
            toolbar: FeedbackToolbarState,
            openFile: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
        ) {
            self.model = model
            self.toolbar = toolbar
            self.openFile = openFile
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

        /// Clicks on a failed attachment block retry its upload.
        func textView(
            _ textView: NSTextView,
            clickedOn _: NSTextAttachmentCellProtocol,
            in _: NSRect,
            at charIndex: Int
        ) {
            guard let attachment = textView.textStorage?.attribute(.attachment, at: charIndex, effectiveRange: nil)
                as? FeedbackTextAttachment else { return }
            if case .failed = model.attachment(id: attachment.attachmentID)?.state {
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
            openFile(url)
        }
    }
}
