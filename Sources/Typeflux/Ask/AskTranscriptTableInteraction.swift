import AppKit

/// Indexes native table paragraphs once per render; geometry follows TextKit layout.
@MainActor final class AskTranscriptTableInteraction: NSObject {
    struct Table {
        var range: NSRange
        var cells: [(block: NSTextTableBlock, range: NSRange)]
        var columnCount: Int { cells.first?.block.table.numberOfColumns ?? 1 }

        @MainActor func frame(in editor: NSTextView) -> NSRect {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return .zero }
            layout.ensureLayout(for: container)
            let rect = cells.reduce(NSRect.null) { rect, cell in
                let glyphs = layout.glyphRange(forCharacterRange: cell.range, actualCharacterRange: nil)
                return rect.union(layout.boundsRect(for: cell.block, glyphRange: glyphs))
            }
            return rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        }
    }

    private weak var editor: AskTranscriptText.Editor?
    private(set) var tables: [Table] = []
    private(set) var hoveredIndex: Int?
    private(set) var preview: AskTablePreviewOverlay?
    private let toolbar = NSStackView()
    private var content = NSAttributedString()

    init(editor: AskTranscriptText.Editor) {
        self.editor = editor
        super.init()
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 8
        toolbar.addArrangedSubview(Self.button("doc.on.doc", title: L("common.copy"),
                                               target: self, action: #selector(copyTable)))
        toolbar.addArrangedSubview(Self.button("arrow.up.left.and.arrow.down.right", title: L("common.expand"),
                                               target: self, action: #selector(expandTable)))
        toolbar.isHidden = true
        editor.addSubview(toolbar)
    }

    static func button(_ symbol: String, title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                              target: target, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func setContent(_ value: NSAttributedString) {
        content = value
        tables = Self.findTables(in: value)
        hoveredIndex = nil
        toolbar.isHidden = true
    }

    static func findTables(in value: NSAttributedString) -> [Table] {
        var result: [Table] = []
        value.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: value.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock else { return }
            if let lastIndex = result.indices.last, result[lastIndex].cells.first?.block.table === block.table,
               NSMaxRange(result[lastIndex].range) == range.location {
                result[lastIndex].range = NSUnionRange(result[lastIndex].range, range)
                result[lastIndex].cells.append((block, range))
            } else {
                result.append(Table(range: range, cells: [(block, range)]))
            }
        }
        return result
    }

    func updateHover(at point: NSPoint?) {
        guard let editor, let point else { hoveredIndex = nil; toolbar.isHidden = true; return }
        if !toolbar.isHidden, toolbar.frame.contains(point) { return }
        hoveredIndex = tables.firstIndex { $0.frame(in: editor).contains(point) }
        updateToolbar()
    }

    func updateToolbar() {
        guard let editor, let index = hoveredIndex, tables.indices.contains(index) else {
            toolbar.isHidden = true; return
        }
        let frame = tables[index].frame(in: editor)
        let visible = frame.intersection(editor.visibleRect)
        guard !visible.isEmpty, !visible.isNull, visible.width >= 70 else { toolbar.isHidden = true; return }
        // A solid surface keeps icons legible over header text while hovering.
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        toolbar.frame = NSRect(x: visible.maxX - 68, y: visible.minY + 3, width: 64, height: 34)
        toolbar.isHidden = false
    }

    @objc func copyTable() {
        guard let index = hoveredIndex, tables.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.tabSeparated(tables[index], in: content), forType: .string)
    }

    static func tabSeparated(_ table: Table, in content: NSAttributedString) -> String {
        var rows: [[String]] = []
        var rowIndex = -1
        var previousBlock: NSTextTableBlock?
        for cell in table.cells {
            let text = (content.string as NSString).substring(with: cell.range)
                .trimmingCharacters(in: .newlines)
            if cell.block === previousBlock {
                rows[rows.count - 1][rows[rows.count - 1].count - 1] += text
                continue
            }
            if rowIndex != cell.block.startingRow { rows.append([]); rowIndex = cell.block.startingRow }
            rows[rows.count - 1].append(text)
            previousBlock = cell.block
        }
        return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    @objc func expandTable() {
        guard let editor, let window = editor.window,
              let index = hoveredIndex, tables.indices.contains(index) else { return }
        preview?.close()
        guard window.attachedSheet == nil else { return }
        editor.askPopover.close()
        let table = tables[index]
        let overlay = AskTablePreviewOverlay(content: content.attributedSubstring(from: table.range),
                                             columns: table.columnCount, onOpenLink: editor.onOpenLink)
        overlay.onClose = { [weak self] in self?.preview = nil }
        preview = overlay
        overlay.present(in: window)
    }

    func dismiss() {
        hoveredIndex = nil
        toolbar.isHidden = true
        preview?.close()
    }
}
