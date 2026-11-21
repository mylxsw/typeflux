import AppKit

/// Indexes native table paragraphs once per render; geometry follows TextKit layout.
@MainActor final class AskTranscriptTableInteraction: NSObject {
    final class Table {
        init(range: NSRange, cells: [(block: NSTextTableBlock, range: NSRange)]) {
            self.range = range
            self.cells = cells
        }
        lazy var headerIndices = cells.indices.filter { cells[$0].block.startingRow == 0 }
            .reduce(into: [Int]()) { indices, i in
                if cells[i].block.startingColumn == indices.count { indices.append(i) }
            }
        var range: NSRange
        var cells: [(block: NSTextTableBlock, range: NSRange)]
        var columnCount: Int { cells.first?.block.table.numberOfColumns ?? 1 }

        @MainActor func cellFrame(_ index: Int, in editor: NSTextView) -> NSRect {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return .zero }
            layout.ensureLayout(for: container)
            let cell = cells[index]
            let glyphs = layout.glyphRange(forCharacterRange: cell.range, actualCharacterRange: nil)
            let bounds = layout.boundsRect(for: cell.block, glyphRange: glyphs)
            return ((cell.block as? AskTableCellBlock)?.visibleFrame(bounds) ?? bounds)
                .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        }

        @MainActor func frame(in editor: NSTextView) -> NSRect {
            cellFrame(0, in: editor).union(cellFrame(cells.count - 1, in: editor))
        }
    }

    private weak var editor: AskTranscriptText.Editor?
    private(set) var tables: [Table] = []
    private(set) var hoveredIndex: Int?
    private(set) var preview: AskTablePreviewOverlay?
    private let toolbar = NSStackView()
    private var columns: [AskTableColumnControls] = []
    var isResizing: Bool { columns.contains { $0.isDragging } }
    private var content = NSAttributedString()

    init(editor: AskTranscriptText.Editor) {
        self.editor = editor
        super.init()
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.addArrangedSubview(Self.actionButton("doc.on.doc", title: L("common.copy"),
                                                   target: self, action: #selector(copyTable)))
        toolbar.addArrangedSubview(Self.actionButton("arrow.up.left.and.arrow.down.right", title: L("common.expand"),
                                                   target: self, action: #selector(expandTable)))
        toolbar.isHidden = true
        editor.addSubview(toolbar)
    }

    static func actionButton(_ symbol: String, title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageLeading
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        return button
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
        guard let editor else { return }
        let previous = columns
        let previousContent = content.string as NSString
        previous.forEach { $0.remove() }
        content = value
        tables = Self.findTables(in: value)
        columns = tables.enumerated().map { index, table in
            let controls = AskTableColumnControls(table: table, in: editor)
            if previous.indices.contains(index), let widths = previous[index].manualWidths,
               table.range.location == previous[index].table.range.location,
               (value.string as NSString).substring(with: table.range)
                .hasPrefix(previousContent.substring(with: previous[index].table.range)) {
                controls.apply(widths)
            }
            controls.onChange = { [weak self, weak editor] in
                self?.updateToolbar()
                editor?.invalidateIntrinsicContentSize()
                editor?.onContentChange?()
                editor?.resumePendingContent()
            }
            return controls
        }
        editor.needsLayout = true
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

    func layout() {
        columns.forEach { $0.layout() }
        updateToolbar()
    }

    func updateHover(at point: NSPoint?) {
        guard let editor, let point else { hoveredIndex = nil; toolbar.isHidden = true; return }
        if !toolbar.isHidden, toolbar.frame.insetBy(dx: -1, dy: -4).contains(point) { return }
        hoveredIndex = tables.firstIndex { $0.frame(in: editor).contains(point) }
        updateToolbar()
    }

    func updateToolbar() {
        guard let editor, let index = hoveredIndex, tables.indices.contains(index) else {
            toolbar.isHidden = true; return
        }
        let frame = tables[index].frame(in: editor)
        let size = toolbar.fittingSize
        let y = frame.minY - size.height - 2
        let target = NSRect(x: frame.maxX - size.width, y: y, width: size.width, height: size.height)
        guard !columns[index].isDragging, editor.visibleRect.intersects(target) else {
            toolbar.isHidden = true
            return
        }
        toolbar.frame = target
        if toolbar.isHidden {
            toolbar.alphaValue = 0
            toolbar.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                toolbar.animator().alphaValue = 1
            }
        }
    }

    @objc func copyTable() {
        guard let index = hoveredIndex, tables.indices.contains(index) else { return }
        Self.copy(tables[index], in: content, to: .general)
    }

    static func copy(_ table: Table, in content: NSAttributedString, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(tabSeparated(table, in: content), forType: .string)
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
                                             columns: table.columnCount, widths: columns[index].manualWidths, onOpenLink: editor.onOpenLink)
        let original = (content.string as NSString).substring(with: table.range)
        overlay.onClose = { [weak self, weak overlay] in
            guard let self else { return }
            defer { self.preview = nil }
            guard let overlay, self.tables.indices.contains(index),
                  self.tables[index].range.location == table.range.location,
                  (self.content.string as NSString).substring(with: self.tables[index].range).hasPrefix(original),
                  overlay.columnControls?.manualWidths != self.columns[index].manualWidths else { return }
            self.columns[index].apply(overlay.columnControls?.manualWidths)
        }
        preview = overlay
        overlay.present(in: window)
    }

    func dismiss() {
        hoveredIndex = nil
        toolbar.isHidden = true
        preview?.close()
    }
}
