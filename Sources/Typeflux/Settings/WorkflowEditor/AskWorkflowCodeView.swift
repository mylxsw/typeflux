import AppKit
import SwiftUI

/// The editor's code area: a plain-text `NSTextView` with line numbers, syntax
/// colors, problem markers, the system find bar and indentation that follows the
/// file. No third-party editor component.
struct AskWorkflowCodeView: NSViewRepresentable {
    @Binding var text: String
    var language: AskWorkflowSyntaxHighlighter.Language
    /// Line (1-based) → message, drawn as a red dot and a note under the line.
    var markers: [Int: String] = [:]
    /// Scrolls to and selects this line once.
    var reveal: Int?
    var isEditable = true
    /// Changes when the user asks to find: the find bar opens.
    var findRequest = 0
    var onRevealed: () -> Void = {}
    var onCursor: (AskWorkflowEditorModel.Cursor) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let textView = AskWorkflowTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Coordinator.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasHorizontalScroller = true
        // Nothing the text view or ruler draws may spill over the editor around it.
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        let ruler = AskWorkflowLineRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.findRequest = findRequest
        textView.string = text
        context.coordinator.highlight(all: true)
        // Scrolling colors what comes into view; edits only recolor around what is visible.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.highlight(all: false)
        }
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            let length = (text as NSString).length
            let valid = selection.filter { $0.rangeValue.upperBound <= length }
            // NSTextView requires at least one range, even when replacing all text.
            textView.selectedRanges = valid.isEmpty
                ? [NSValue(range: NSRange(location: min(selection.first?.rangeValue.location ?? 0, length), length: 0))]
                : valid
            coordinator.highlight(all: true)
        } else if coordinator.language != language {
            coordinator.highlight(all: true)
        }
        coordinator.ruler?.problems = markers
        coordinator.ruler?.needsDisplay = true
        if let codeView = textView as? AskWorkflowTextView, codeView.problems != markers {
            codeView.problems = markers
            codeView.needsDisplay = true
        }
        if findRequest != coordinator.findRequest {
            coordinator.findRequest = findRequest
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
        }
        if let reveal, coordinator.revealed != reveal {
            coordinator.revealed = reveal
            coordinator.reveal(line: reveal)
            DispatchQueue.main.async { onRevealed() }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        var parent: AskWorkflowCodeView
        weak var textView: NSTextView?
        weak var ruler: AskWorkflowLineRuler?
        var language: AskWorkflowSyntaxHighlighter.Language?
        var revealed: Int?
        var findRequest = 0
        var scrollObserver: NSObjectProtocol?

        init(_ parent: AskWorkflowCodeView) {
            self.parent = parent
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        /// Reports the caret's line and column (1-based) for the status bar.
        func textViewDidChangeSelection(_: Notification) {
            guard let textView else { return }
            let content = textView.string as NSString
            let caret = min(textView.selectedRange().location, content.length)
            let before = content.substring(to: caret)
            let line = before.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let column = (before.components(separatedBy: "\n").last?.count ?? 0) + 1
            parent.onCursor(.init(line: line, column: column))
        }

        func textDidChange(_: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight(all: false)
            ruler?.needsDisplay = true
        }

        /// Return keeps the line's indentation; Tab inserts spaces.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let content = textView.string as NSString
                let caret = textView.selectedRange().location
                let line = content.lineRange(for: NSRange(location: min(caret, content.length), length: 0))
                let prefix = content.substring(with: line).prefix { $0 == " " || $0 == "\t" }
                textView.insertText("\n" + prefix, replacementRange: textView.selectedRange())
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText(String(repeating: " ", count: Self.indentWidth(textView.string)),
                                    replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        /// Two spaces when the file mostly indents by two, else four.
        static func indentWidth(_ text: String) -> Int {
            AskWorkflowCodeIndentation.width(of: text)
        }

        func highlight(all: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            language = parent.language
            let content = textView.string as NSString
            var range = NSRange(location: 0, length: content.length)
            if !all || content.length > AskWorkflowSyntaxHighlighter.fullHighlightLimit,
               let visible = textView.enclosingScrollView?.contentView.bounds,
               let layout = textView.layoutManager, let container = textView.textContainer {
                let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
                let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                // Whole lines, with some margin for multi-line strings.
                let start = max(0, characters.location - 2000)
                let end = min(content.length, characters.upperBound + 2000)
                range = content.lineRange(for: NSRange(location: start, length: end - start))
            }
            let highlighter = AskWorkflowSyntaxHighlighter(language: parent.language)
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: range)
            for span in highlighter.spans(in: textView.string, range: range) {
                storage.addAttribute(.foregroundColor, value: Self.color(span.token), range: span.range)
            }
            storage.endEditing()
        }

        static func color(_ token: AskWorkflowSyntaxHighlighter.Token) -> NSColor {
            switch token {
            case .comment: .systemGray
            case .string: .systemRed
            case .keyword: .systemPink
            case .number: .systemYellow.blended(withFraction: 0.35, of: .systemOrange) ?? .systemOrange
            case .call: .systemTeal
            case .key: .systemBlue
            }
        }

        func reveal(line: Int) {
            guard let textView else { return }
            let content = textView.string as NSString
            var location = 0
            var current = 1
            while current < line, location < content.length {
                location = NSMaxRange(content.lineRange(for: NSRange(location: location, length: 0)))
                current += 1
            }
            let range = content.lineRange(for: NSRange(location: min(location, content.length), length: 0))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
    }
}

/// Line numbers, with a red dot and the message on lines that have a problem.
final class AskWorkflowLineRuler: NSRulerView {
    var problems: [Int: String] = [:]
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(changed),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        needsDisplay = true
    }

    /// Only the numbers and markers: no default border line.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in _: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.blended(withFraction: 0.04, of: .labelColor)?.setFill()
        bounds.fill()
        let content = textView.string as NSString
        let visible = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = 1
        var index = 0
        // Count lines before the visible part.
        while index < characters.location, index < content.length {
            index = NSMaxRange(content.lineRange(for: NSRange(location: index, length: 0)))
            if index <= characters.location {
                line += 1
            }
        }
        index = content.lineRange(for: NSRange(location: min(characters.location, content.length), length: 0)).location
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let inset = textView.textContainerInset.height
        repeat {
            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(lineRange.location, max(0, content.length - 1)))
            var rect = content.length == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.y += inset - visible.minY
            let marked = problems[line] != nil
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: marked ? NSColor.systemRed : NSColor.tertiaryLabelColor
            ]
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: rect.minY + (rect.height - size.height) / 2),
                       withAttributes: attributes)
            if marked {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: rect.minY + rect.height / 2 - 3, width: 6, height: 6)).fill()
            }
            index = NSMaxRange(lineRange)
            line += 1
        } while index < content.length && index <= characters.upperBound
    }
}

/// The code view's text view: lines with a problem get a red tint and the message
/// at the right edge, where the eye already is.
final class AskWorkflowTextView: NSTextView {
    var problems: [Int: String] = [:]

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !problems.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let content = string as NSString
        let origin = textContainerOrigin
        let font = NSFont.systemFont(ofSize: 11)
        for (line, message) in problems {
            guard let range = Self.range(ofLine: line, in: content) else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0),
                                           actualCharacterRange: nil)
            var lineRect = content.length == 0 ? NSRect(x: 0, y: 0, width: 0, height: 18)
                : layout.lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, layout.numberOfGlyphs - 1)),
                                          effectiveRange: nil, withoutAdditionalLayout: true)
            lineRect.origin.y += origin.y
            lineRect.origin.x = bounds.minX
            lineRect.size.width = bounds.width
            guard lineRect.intersects(rect) else { continue }
            NSColor.systemRed.withAlphaComponent(0.12).setFill()
            lineRect.fill()
            _ = container
            let label = "↳ " + message as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemRed]
            let size = label.size(withAttributes: attributes)
            let maxWidth = min(size.width, visibleRect.width * 0.55)
            let pill = NSRect(x: visibleRect.maxX - maxWidth - 22, y: lineRect.minY + 1,
                              width: maxWidth + 14, height: lineRect.height - 2)
            NSColor.systemRed.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
            label.draw(with: NSRect(x: pill.minX + 7, y: pill.minY + (pill.height - size.height) / 2,
                                    width: maxWidth, height: size.height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
    }

    /// The character range of a 1-based line.
    static func range(ofLine line: Int, in content: NSString) -> NSRange? {
        var location = 0
        var current = 1
        while current < line {
            guard location < content.length else { return nil }
            location = NSMaxRange(content.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        guard location <= content.length else { return nil }
        return content.lineRange(for: NSRange(location: location, length: 0))
    }
}
