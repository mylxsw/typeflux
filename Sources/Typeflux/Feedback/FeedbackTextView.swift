import AppKit

/// The rich text body of the feedback window: a TextKit 1 text view that restricts formats,
/// turns pasted/dropped files into attachment callbacks and draws a placeholder and drop hint.
final class FeedbackTextView: NSTextView {
    var placeholder = ""
    var onFiles: (([URL]) -> Void)?
    var onImageData: ((Data) -> Void)?
    var onLinkRequest: (() -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?
    private(set) var isDropTargeted = false {
        didSet {
            if oldValue != isDropTargeted {
                needsDisplay = true
            }
        }
    }

    init() {
        // TextKit 1, with the layout manager that draws list markers.
        let storage = NSTextStorage()
        let layoutManager = FeedbackLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        usesFontPanel = false
        textContainerInset = NSSize(width: 14, height: 12)
        typingAttributes = FeedbackRichText.baseAttributes
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let origin = NSPoint(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: textContainerInset.height
            )
            let rect = NSRect(origin: origin, size: NSSize(width: bounds.width - origin.x * 2, height: bounds.height))
            (placeholder as NSString).draw(
                in: rect,
                withAttributes: [.font: FeedbackRichText.baseFont, .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }
        if isDropTargeted {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": toggleInline(.bold)
        case "i": toggleInline(.italic)
        case "k": onLinkRequest?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Return on an empty list/quote line ends the block; Return after a heading starts plain text.
    /// Returns true when the key was handled here.
    func handleNewline() -> Bool {
        guard let format = currentBlockFormat else { return false }
        let nsText = string as NSString
        let cursor = min(selectedRange().location, nsText.length)
        let paragraph = nsText.paragraphRange(for: NSRange(location: cursor, length: 0))
        let isEmptyLine = nsText.substring(with: paragraph).trimmingCharacters(in: .newlines).isEmpty
        switch format {
        case .bulletList, .numberedList, .quote:
            guard isEmptyLine else { return false }
            toggleBlock(format)
            return true
        case .heading:
            insertNewlineIgnoringFieldEditor(nil)
            typingAttributes = FeedbackRichText.baseAttributes
            return true
        case .code:
            return false
        }
    }

    // MARK: - Paste

    override func paste(_: Any?) {
        paste(from: .general)
    }

    /// Pastes files and screenshots as attachments and text with the restricted formats.
    func paste(from pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onFiles?(urls)
        } else if let image = Self.pastedImageData(from: pasteboard) {
            onImageData?(image)
        } else if let attributed = Self.pastedAttributedString(from: pasteboard) {
            insertSanitized(attributed)
        }
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    /// A screenshot on the pasteboard (PNG/TIFF) when it carries no text.
    static func pastedImageData(from pasteboard: NSPasteboard) -> Data? {
        let hasText = pasteboard.string(forType: .string)?.isEmpty == false
        guard !hasText else { return nil }
        return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    static func pastedAttributedString(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return attributed
        }
        if let data = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: data, documentAttributes: nil) {
            return attributed
        }
        if let text = pasteboard.string(forType: .string) {
            return NSAttributedString(string: text)
        }
        return nil
    }

    private func insertSanitized(_ attributed: NSAttributedString) {
        let clean = FeedbackRichText.sanitized(attributed)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: clean.string) else { return }
        textStorage?.replaceCharacters(in: range, with: clean)
        setSelectedRange(NSRange(location: range.location + clean.length, length: 0))
        didChangeText()
    }

    // MARK: - Drag and drop

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return super.draggingEntered(sender) }
        isDropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFiles?(urls)
        return true
    }

    // MARK: - Attachments

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = attachmentRemovalTarget(at: point), let onRemoveAttachment {
            onRemoveAttachment(id)
            return
        }
        super.mouseDown(with: event)
    }

    /// Editable text views may select attachments without sending the cell-click delegate callback.
    /// Hit-test the drawn controls using TextKit's current layout and the actual mouse event.
    func attachmentRemovalTarget(at point: NSPoint) -> UUID? {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        var target: UUID?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let attachment = value as? FeedbackTextAttachment,
                  let cell = attachment.attachmentCell as? FeedbackAttachmentCell else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let frame = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            if cell.removeButtonHitRect(in: frame)?.contains(point) == true {
                target = attachment.attachmentID
                stop.pointee = true
            }
        }
        return target
    }

    /// Inserts the attachment block on its own paragraph after the paragraph at the cursor, so
    /// text and attachments can alternate.
    func insertAttachmentBlock(
        _ attachment: FeedbackTextAttachment
    ) {
        guard let storage = textStorage else { return }
        let nsText = storage.string as NSString
        var insertion = min(selectedRange().location, nsText.length)
        let paragraph = nsText.paragraphRange(for: NSRange(location: insertion, length: 0))
        insertion = NSMaxRange(paragraph)

        let block = NSMutableAttributedString()
        if insertion > 0, nsText.character(at: insertion - 1) != 0x0A {
            block.append(NSAttributedString(string: "\n", attributes: FeedbackRichText.baseAttributes))
        }
        let attachmentString = NSMutableAttributedString(attachment: attachment)
        attachmentString.addAttributes(
            FeedbackRichText.baseAttributes, range: NSRange(location: 0, length: attachmentString.length)
        )
        block.append(attachmentString)
        block.append(NSAttributedString(string: "\n", attributes: FeedbackRichText.baseAttributes))

        let range = NSRange(location: insertion, length: 0)
        guard shouldChangeText(in: range, replacementString: block.string) else { return }
        storage.replaceCharacters(in: range, with: block)
        setSelectedRange(NSRange(location: insertion + block.length, length: 0))
        typingAttributes = FeedbackRichText.baseAttributes
        didChangeText()
    }

    /// The attachment blocks currently in the body, in order.
    var attachmentIDs: [UUID] {
        guard let storage = textStorage else { return [] }
        var ids: [UUID] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? FeedbackTextAttachment {
                ids.append(attachment.attachmentID)
            }
        }
        return ids
    }

    func removeAttachmentBlock(id: UUID) {
        guard let storage = textStorage else { return }
        var target: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(
            location: 0,
            length: storage.length
        )) { value, range, stop in
            if let attachment = value as? FeedbackTextAttachment, attachment.attachmentID == id {
                target = range
                stop.pointee = true
            }
        }
        guard let target else { return }
        guard shouldChangeText(in: target, replacementString: "") else { return }
        storage.replaceCharacters(in: target, with: "")
        didChangeText()
    }

    /// Redraws the block for `id` after its state changed (progress, uploaded, failed).
    func refreshAttachment(id: UUID) {
        guard let storage = textStorage, let layout = layoutManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? FeedbackTextAttachment, attachment.attachmentID == id {
                layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                layout.invalidateDisplay(forCharacterRange: range)
            }
        }
    }
}
