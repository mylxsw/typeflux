import AppKit
import Markdown
import SwiftUI

/// A single text storage per message makes selection continuous across Markdown
/// blocks. Unchanged messages never replace their storage during stream updates.
struct AskTranscriptText: NSViewRepresentable {
    // Parsing different visible messages must not create one CPU-bound thread per row.
    private static let parsingQueue = DispatchQueue(label: "typeflux.transcript-parse", qos: .userInitiated)
    var text: String
    @State private var layoutRevision = 0
    var markdown = true
    var onAsk: ((String, String) -> Void)? = nil
    /// Saves the selected text to the notebook; nil leaves the action out.
    var onSaveNote: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    /// In a conversation window, links open in the side panel (or the browser, by setting).
    @Environment(\.askSidePanelActions) private var sidePanelActions

    func makeNSView(context _: Context) -> Editor { Self.makeEditor() }

    static func makeEditor() -> Editor {
        let editor = Editor()
        editor.textContainer?.replaceLayoutManager(AskRoundedBackgroundLayoutManager())
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = true
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        // SwiftUI proposes the wrapping width before it assigns the native frame.
        // Tracking that old frame can invalidate or collapse the measured layout.
        editor.textContainer?.widthTracksTextView = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return editor
    }

    func updateNSView(_ editor: Editor, context _: Context) {
        // Read the revision so asynchronous text delivery triggers a SwiftUI sizing pass.
        _ = layoutRevision
        editor.onContentChange = { layoutRevision &+= 1 }
        editor.onAsk = onAsk
        editor.onSaveNote = onSaveNote
        editor.onOpenLink = sidePanelActions?.openLink
        editor.requestContent(text, markdown: markdown, dark: colorScheme == .dark)
    }

    static func dismantleNSView(_ editor: Editor, coordinator: ()) {
        editor.onContentChange = nil
        editor.tableInteraction.dismiss()
        editor.cancelPreparation()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Editor, context _: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return nsView.measuredSize(width: width)
    }

    final class Editor: NSTextView {
        lazy var tableInteraction = AskTranscriptTableInteraction(editor: self)
        private var tableTrackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tableTrackingArea { removeTrackingArea(tableTrackingArea) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self)
            addTrackingArea(area)
            tableTrackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            tableInteraction.updateHover(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            tableInteraction.updateHover(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            tableInteraction.updateHover(at: nil)
        }

        override func layout() {
            super.layout()
            tableInteraction.updateToolbar()
        }

        var preparation: any LatestBackgroundWorking = LatestBackgroundWork(
            label: "typeflux.transcript-parse", queue: AskTranscriptText.parsingQueue
        )
        var renderCache = AskTranscriptRenderCache.shared
        var onContentChange: (() -> Void)?

        func measuredSize(width: CGFloat) -> CGSize? {
            guard let container = textContainer, let layout = layoutManager else { return nil }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            // TextKit already caches valid layout. A separate width-only cache can
            // retain an empty or partial height across native layout invalidations.
            return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
        }

        private var requested: (text: String, markdown: Bool, dark: Bool)?
        private var contentGeneration = UUID()
        private var source: String?
        private var dark = false
        private var usesMarkdown = true
        private var dragging = false
        private var pending: (String, Bool, Bool)?
        var onAsk: ((String, String) -> Void)? {
            didSet { if onAsk == nil { askPopover.close() } }
        }
        var onSaveNote: ((String) -> Void)?
        /// Routes link clicks; nil keeps AppKit's default of opening the URL.
        var onOpenLink: ((URL, Bool) -> Void)?
        let askPopover = NSPopover()

        override func clicked(onLink link: Any, at charIndex: Int) {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return }
            if let onOpenLink {
                onOpenLink(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            } else if url.scheme?.lowercased() != AskLinkRouter.fileScheme {
                // A workspace link means nothing outside a conversation window.
                super.clicked(onLink: link, at: charIndex)
            }
        }

        var selectedExcerpt: String? {
            let range = selectedRange()
            guard range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return nil }
            let excerpt = (string as NSString).substring(with: range)
            return excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : excerpt
        }

        func showSelectionAction() {
            askPopover.close()
            guard onAsk != nil, let excerpt = selectedExcerpt, window != nil,
                  let layout = layoutManager, let container = textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
            var anchor = layout.boundingRect(forGlyphRange: glyphs, in: container)
            anchor.origin.x += textContainerOrigin.x
            anchor.origin.y += textContainerOrigin.y
            // A long drag may scroll the start of the selection out of view.
            // Anchor to the visible part instead of silently losing the action.
            anchor = anchor.intersection(visibleRect)
            guard !anchor.isNull, !anchor.isEmpty else { return }
            anchor.size.height = min(anchor.height, 18)
            askPopover.behavior = .transient
            askPopover.animates = false
            let actions = AskSelectionAction.standard + (onSaveNote == nil ? [] : [.note])
            let host = NSHostingController(rootView:
                AskSelectionActionBar(actions: actions) { [weak self] action in
                    self?.perform(action, excerpt: excerpt)
                }
                    .onCopyCommand { [NSItemProvider(object: excerpt as NSString)] }
            )
            // The popover otherwise sizes itself before SwiftUI has measured the
            // labels, and compresses two of the four into an ellipsis.
            host.view.layoutSubtreeIfNeeded()
            askPopover.contentViewController = host
            askPopover.contentSize = host.view.fittingSize
            // The text view is flipped, so minY is the visual top of the selection.
            askPopover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
        }

        /// Selecting text used to cost four steps: select, press Ask, fill in an
        /// optional question in a modal, then find the excerpt back in the
        /// composer. Each action here finishes in one click, and the modal is gone.
        func perform(_ action: AskSelectionAction, excerpt: String) {
            switch action {
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(excerpt, forType: .string)
            case .note:
                onSaveNote?(excerpt)
            default:
                onAsk?(excerpt, action.question)
            }
            askPopover.close()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { askPopover.close(); tableInteraction.dismiss() }
            super.viewWillMove(toWindow: newWindow)
        }

        func cancelPreparation() {
            contentGeneration = UUID(); requested = nil; pending = nil; preparation.cancel()
        }

        override func keyUp(with event: NSEvent) {
            super.keyUp(with: event)
            if event.modifierFlags.contains(.shift) { showSelectionAction() }
        }

        override func mouseDown(with event: NSEvent) {
            askPopover.close()
            dragging = true
            defer {
                dragging = false
                if let pending {
                    self.pending = nil; requestContent(pending.0, markdown: pending.1, dark: pending.2)
                }
                showSelectionAction()
            }
            super.mouseDown(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            tableInteraction.updateHover(at: nil)
            nextResponder?.scrollWheel(with: event)
        }

        /// Parse outside AppKit's update/layout pass. Each editor keeps only its
        /// running parse and newest replacement, including during fast streams.
        func requestContent(_ text: String, markdown: Bool, dark: Bool) {
            if let requested, requested.text == text, requested.markdown == markdown, requested.dark == dark { return }
            if dragging { pending = (text, markdown, dark); return }
            requested = (text, markdown, dark)
            let generation = UUID(); contentGeneration = generation
            guard source != text || self.dark != dark || usesMarkdown != markdown else {
                preparation.cancel(); return
            }
            if let rendered = renderCache.value(text: text, markdown: markdown, dark: dark) {
                preparation.cancel()
                applyContent(text, markdown: markdown, dark: dark, document: nil, rendered: rendered)
                return
            }
            guard markdown else {
                preparation.cancel()
                applyContent(text, markdown: false, dark: dark, document: nil)
                return
            }
            var document: Markdown.Document?
            preparation.submit({ document = Markdown.Document(parsing: AskMarkdownFences.normalize(text)) }, completion: { [weak self] result in
                guard let self, contentGeneration == generation else { return }
                guard case .success = result, let document else {
                    requested = nil
                    if !dragging { applyContent(text, markdown: false, dark: dark, document: nil) }
                    return
                }
                if dragging { pending = (text, markdown, dark); requested = nil; return }
                applyContent(text, markdown: true, dark: dark, document: document)
            })
        }

        /// Synchronous entry for deterministic text-layout fixtures.
        func setContent(_ text: String, markdown: Bool, dark: Bool) {
            contentGeneration = UUID(); requested = nil; preparation.cancel()
            applyContent(text, markdown: markdown, dark: dark, document: nil)
        }

        private func applyContent(_ text: String, markdown: Bool, dark: Bool, document: Markdown.Document?,
                                  rendered: NSAttributedString? = nil) {
            guard source != text || self.dark != dark || usesMarkdown != markdown else { return }
            if dragging {
                pending = (text, markdown, dark); return
            }
            let oldSelection = selectedRange()
            let oldString = string as NSString
            source = text; self.dark = dark; usesMarkdown = markdown
            let rendered = rendered ?? AskMarkdownText.render(text, markdown: markdown, document: document)
            renderCache.insert(rendered, text: text, markdown: markdown, dark: dark)
            textStorage?.setAttributedString(rendered)
            tableInteraction.setContent(rendered)
            // Preserve a selection only if the selected prefix is still identical.
            if NSMaxRange(oldSelection) <= oldString.length, NSMaxRange(oldSelection) <= rendered.length,
               oldString.substring(to: NSMaxRange(oldSelection)) == (rendered.string as NSString)
               .substring(to: NSMaxRange(oldSelection)) {
                setSelectedRange(oldSelection)
            }
            invalidateIntrinsicContentSize()
            // Intrinsic-size invalidation alone does not reliably remeasure a
            // representable inside LazyVStack. Defer state changes out of updateNSView.
            DispatchQueue.main.async { [weak self] in self?.onContentChange?() }
        }
    }
}

enum AskMarkdownText {
    /// Regular-weight conversation text, shared by assistant and user messages.
    static let bodySize: CGFloat = 13.5
    static let lineSpacing: CGFloat = 6
    static let paragraphSpacing: CGFloat = 10
    /// Where list text starts; the marker hangs in the space before it.
    static let listIndent: CGFloat = 20

    /// Inline code chips and code blocks share one translucent wash.
    static let codeFill = NSColor(name: "AskCodeFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05)
    }

    /// A list item's paragraph: the marker hangs before a tab stop where the text starts.
    static func listStyle(_ base: NSParagraphStyle, depth: Int) -> NSMutableParagraphStyle {
        let style = mutable(base)
        let indent = listIndent * CGFloat(depth)
        style.headIndent = indent
        style.firstLineHeadIndent = indent - listIndent + 4
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = listIndent
        style.paragraphSpacing = 4
        return style
    }

    /// The last item of an outermost list keeps the body's paragraph gap.
    static func closeList(in result: NSMutableAttributedString) {
        guard result.length > 0,
              let current = result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil)
                  as? NSParagraphStyle,
              current.textBlocks.isEmpty else { return }
        let style = mutable(current)
        style.paragraphSpacing = paragraphSpacing
        var start = result.length - 1
        let string = result.string as NSString
        while start > 0, string.character(at: start - 1) != 10 { start -= 1 }
        result.addAttribute(.paragraphStyle, value: style,
                            range: NSRange(location: start, length: result.length - start))
    }

    /// A mutable copy of a paragraph style, for per-block adjustments.
    static func mutable(_ style: NSParagraphStyle) -> NSMutableParagraphStyle {
        let copy = NSMutableParagraphStyle()
        copy.setParagraphStyle(style)
        return copy
    }

    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 20, weight: .bold)
        case 2: return .systemFont(ofSize: 17, weight: .bold)
        case 3: return .systemFont(ofSize: 15.5, weight: .bold)
        default: return .systemFont(ofSize: bodySize, weight: .bold)
        }
    }

    static func render(_ text: String, markdown: Bool = true, document: Markdown.Document? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        guard markdown else { return NSAttributedString(string: text, attributes: base) }
        let result = NSMutableAttributedString()
        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        func visit(_ node: any Markup, _ inherited: [NSAttributedString.Key: Any], listDepth: Int = 0) {
            var attributes = inherited
            if let text = node as? Markdown.Text {
                append(text.string, attributes); return
            }
            if let code = node as? InlineCode {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                attributes[.backgroundColor] = codeFill
                append(code.code, attributes); return
            }
            if let code = node as? CodeBlock {
                let block = AskCodeBlock()
                let style = mutable(paragraph)
                style.textBlocks = [block]
                style.lineSpacing = 3
                style.paragraphSpacing = 0
                attributes[.paragraphStyle] = style
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                append(code.code + (code.code.hasSuffix("\n") ? "" : "\n"), attributes); return
            }
            if let heading = node as? Heading {
                attributes[.font] = headingFont(level: heading.level)
                let style = mutable(paragraph)
                style.paragraphSpacingBefore = result.length == 0 ? 0 : 8
                style.paragraphSpacing = 6
                attributes[.paragraphStyle] = style
            }
            if node is BlockQuote {
                let quoted = paragraph.mutableCopy() as! NSMutableParagraphStyle
                quoted.headIndent = 12; quoted.firstLineHeadIndent = 12
                attributes[.paragraphStyle] = quoted
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            if node is Strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let table = node as? Markdown.Table {
                let rows: [any Markup] = [table.head] + table.body.children.map { $0 }
                let layout = AskMarkdownTable(columnCount: table.head.childCount, rowCount: rows.count)
                for (rowIndex, row) in rows.enumerated() {
                    for (columnIndex, cell) in row.children.enumerated() {
                        let cellAttributes = layout.attributes(
                            row: rowIndex, column: columnIndex,
                            alignment: table.columnAlignments[columnIndex], inherited: attributes
                        )
                        visit(cell, cellAttributes)
                        // Each cell needs its own paragraph, including empty cells.
                        append("\n", cellAttributes)
                    }
                }
                return
            }
            if node is Strong {
                attributes[.font] = NSFontManager.shared.convert(
                    attributes[.font] as! NSFont,
                    toHaveTrait: .boldFontMask
                )
            }
            if node is Emphasis {
                attributes[.font] = NSFontManager.shared.convert(
                    attributes[.font] as! NSFont,
                    toHaveTrait: .italicFontMask
                )
            }
            if let link = node as? Markdown.Link, let destination = link.destination {
                if let url = URL(string: destination), ["https", "http", "mailto"].contains(url.scheme ?? "") {
                    attributes[.link] = url
                } else if let url = AskLinkRouter.link(forDestination: destination) {
                    attributes[.link] = url
                }
            }
            if node is SoftBreak {
                append(" ", attributes); return
            }
            if node is LineBreak {
                append("\n", attributes); return
            }
            if node is ThematicBreak {
                append("────────────\n", attributes); return
            }
            if let list = node as? OrderedList {
                attributes[.paragraphStyle] = listStyle(attributes[.paragraphStyle] as? NSParagraphStyle ?? paragraph,
                                                         depth: listDepth + 1)
                for (index, child) in list.children.enumerated() {
                    append("\(Int(list.startIndex) + index).\t", attributes)
                    visit(child, attributes, listDepth: listDepth + 1)
                }
                if listDepth == 0 { closeList(in: result) }
                return
            }
            if let list = node as? UnorderedList {
                attributes[.paragraphStyle] = listStyle(attributes[.paragraphStyle] as? NSParagraphStyle ?? paragraph,
                                                         depth: listDepth + 1)
                for child in list.children {
                    append("•\t", attributes)
                    visit(child, attributes, listDepth: listDepth + 1)
                }
                if listDepth == 0 { closeList(in: result) }
                return
            }
            var previousWasTable = false
            for child in node.children {
                let start = result.length
                visit(child, attributes, listDepth: listDepth)
                // Table margins alone do not reliably separate the next text paragraph in TextKit.
                if previousWasTable, result.length > start,
                   let current = result.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle,
                   current.textBlocks.isEmpty {
                    let style = mutable(current)
                    style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 16)
                    let range = (result.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
                    result.addAttribute(.paragraphStyle, value: style, range: range)
                }
                previousWasTable = child is Markdown.Table
            }
            if node is Paragraph || node is Heading {
                append("\n", attributes)
            }
        }
        visit(document ?? Markdown.Document(parsing: AskMarkdownFences.normalize(text)), base)
        // TextKit requires the final cell's paragraph terminator to lay out a table.
        if result.string.hasSuffix("\n"),
           (result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil) as? NSParagraphStyle)?
           .textBlocks.isEmpty != false {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }
}

/// A fenced code block: a rounded, hairline-framed panel with padding.
final class AskCodeBlock: NSTextBlock {
    static let corner: CGFloat = 14

    override init() {
        super.init()
        setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
        setWidth(12, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxY)
        setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        setContentWidth(100, type: .percentageValueType)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// TextKit's bounds include margins. Painting them makes the panel touch
    /// the next paragraph even though the text layout reserved a gap.
    func panelRect(in bounds: NSRect) -> NSRect {
        let top = width(for: .margin, edge: .minY)
        let bottom = width(for: .margin, edge: .maxY)
        return NSRect(x: bounds.minX, y: bounds.minY + top,
                      width: bounds.width, height: max(0, bounds.height - top - bottom))
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let path = NSBezierPath(roundedRect: panelRect(in: frameRect).insetBy(dx: 0.25, dy: 0.25),
                                xRadius: Self.corner, yRadius: Self.corner)
        AskMarkdownText.codeFill.setFill()
        path.fill()
        AskTableCellBlock.rule.setStroke()
        path.lineWidth = 1 / max(1, controlView?.window?.backingScaleFactor ?? 2)
        path.stroke()
    }
}

/// Draws background-colour runs (inline code) as rounded chips instead of
/// TextKit's square fills. Selection highlights keep the system drawing.
final class AskRoundedBackgroundLayoutManager: NSLayoutManager {
    static let chipCorner: CGFloat = 5

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard color == AskMarkdownText.codeFill else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        // The transcript's text view has no container inset, so container and
        // view coordinates share their origin.
        for rect in Self.chipRects(rects: (0 ..< rectCount).map { rectArray[$0] }, glyphs: glyphBounds(charRange)) {
            NSBezierPath(roundedRect: rect, xRadius: Self.chipCorner, yRadius: Self.chipCorner).fill()
        }
    }

    /// The glyphs' own bounds on each line, in text container coordinates. A run
    /// that wraps would otherwise fill to the end of its first line.
    private func glyphBounds(_ charRange: NSRange) -> [NSRect] {
        guard let container = textContainers.first else { return [] }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var result: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            if part.length > 0 { result.append(self.boundingRect(forGlyphRange: part, in: container)) }
        }
        return result
    }

    /// One chip per line: the glyph bounds, a little wider so the code has
    /// room, at the height TextKit gave the background run.
    /// TextKit may pass one line or several per call, so each rect is matched
    /// with the glyph bounds on the same line.
    static func chipRects(rects: [NSRect], glyphs: [NSRect]) -> [NSRect] {
        rects.map { rect in
            let line = glyphs.first { $0.midY >= rect.minY && $0.midY <= rect.maxY }
            let minX = line.map { max(rect.minX, $0.minX) } ?? rect.minX
            let maxX = line.map { min(rect.maxX, $0.maxX) } ?? rect.maxX
            return NSRect(x: minX - 3, y: rect.minY + 1,
                          width: max(0, maxX - minX) + 6, height: max(0, rect.height - 2))
        }
    }
}
