import AppKit

/// Resizing edits view-local blocks. The render cache and other messages can share the source blocks.
@MainActor final class AskTableColumnControls {
    typealias Table = AskTranscriptTableInteraction.Table

    private weak var view: NSTextView?
    let table: Table
    private var handles: [Handle] = []
    private let guide = NSView()
    private let widthLabel = NSTextField(labelWithString: "")
    private var localBlocks = false
    private var drag: (column: Int, x: CGFloat, width: CGFloat, start: [CGFloat])?
    private(set) var manualWidths: [CGFloat]?
    var onChange: (() -> Void)?
    var isDragging: Bool { drag != nil }

    init(table: Table, in view: NSTextView) {
        self.table = table
        self.view = view
        guide.wantsLayer = true
        guide.layer?.backgroundColor = NSColor.systemBlue.cgColor
        guide.isHidden = true
        view.addSubview(guide)
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        widthLabel.alignment = .center
        widthLabel.textColor = .labelColor
        widthLabel.drawsBackground = true
        widthLabel.backgroundColor = .controlBackgroundColor
        widthLabel.wantsLayer = true
        widthLabel.layer?.cornerRadius = 4
        widthLabel.layer?.masksToBounds = true
        widthLabel.isHidden = true
        view.addSubview(widthLabel)
        for column in table.headerIndices.dropLast().indices {
            let handle = Handle()
            handle.column = column
            handle.controls = self
            handles.append(handle)
            view.addSubview(handle)
        }
    }

    func remove() {
        handles.forEach { $0.removeFromSuperview() }
        guide.removeFromSuperview()
        widthLabel.removeFromSuperview()
    }

    func layout() {
        guard let view else { return }
        for (column, handle) in handles.enumerated() {
            let rect = table.cellFrame(table.headerIndices[column], in: view)
            handle.frame = NSRect(x: rect.maxX - 6, y: rect.minY, width: 12, height: rect.height)
        }
        if let drag {
            let rect = table.frame(in: view)
            let cell = table.cellFrame(table.headerIndices[drag.column], in: view)
            widthLabel.stringValue = "\(Int(cell.width.rounded())) pt"
            widthLabel.frame = NSRect(x: cell.maxX - 53, y: cell.midY - 7, width: 46, height: 15)
            guide.frame = NSRect(x: handles[drag.column].frame.midX, y: rect.minY, width: 1, height: rect.height)
        }
    }

    private var automatic: [CGFloat] {
        (table.cells.first?.block.table as? AskTextTable)?.automaticWidths ?? []
    }

    func apply(_ widths: [CGFloat]?) {
        guard let storage = view?.textStorage else { return }
        let values = widths ?? automatic
        guard values.count == table.columnCount else { return }
        storage.beginEditing()
        if !localBlocks {
            var blocks: [ObjectIdentifier: NSTextTableBlock] = [:]
            for index in table.cells.indices {
                let (source, range) = table.cells[index]
                let key = ObjectIdentifier(source)
                let block = blocks[key] ?? AskMarkdownTable.cell(table: source.table, row: source.startingRow,
                    column: source.startingColumn, width: values[source.startingColumn])
                blocks[key] = block
                storage.enumerateAttribute(.paragraphStyle, in: range) { style, run, _ in
                    guard let style = style as? NSParagraphStyle else { return }
                    let copy = AskMarkdownText.mutable(style)
                    copy.textBlocks = [block]
                    storage.addAttribute(.paragraphStyle, value: copy, range: run)
                }
                table.cells[index].block = block
            }
            localBlocks = true
        } else {
            for (block, _) in table.cells {
                block.setContentWidth(values[block.startingColumn], type: .percentageValueType)
            }
            storage.edited(.editedAttributes, range: table.range, changeInLength: 0)
        }
        storage.endEditing()
        manualWidths = widths
        view?.needsDisplay = true
        layout()
        onChange?()
    }

    final class Handle: NSView {
        weak var controls: AskTableColumnControls?
        var column = 0

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: bounds.midX, y: bounds.midY - 7, width: 1, height: 14).fill()
        }

        override func mouseDown(with event: NSEvent) {
            guard let controls, let view = controls.view else { return }
            if event.clickCount == 2 { controls.apply(nil); return }
            // TextKit distributes percentages over content, after reserving each cell's padding.
            let padding = 2 * AskMarkdownTable.horizontalPadding * CGFloat(controls.table.columnCount)
            let width = controls.table.frame(in: view).width - padding
            guard width > 0 else { return }
            controls.drag = (column, event.locationInWindow.x, width, controls.manualWidths ?? controls.automatic)
            controls.guide.isHidden = false
            controls.widthLabel.isHidden = false
            controls.layout()
            controls.onChange?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let controls, let drag = controls.drag else { return }
            var widths = drag.start
            let pair = widths[column] + widths[column + 1]
            // Even on a narrow table the pair needs room to trade width. Never
            // snap an already smaller column up to the minimum on first movement.
            let minimum = min(pair / 4, 100 * 28 / drag.width)
            let lower = min(widths[column], minimum)
            let upper = pair - min(widths[column + 1], minimum)
            let delta = 100 * (event.locationInWindow.x - drag.x) / drag.width
            widths[column] = min(upper, max(lower, widths[column] + delta))
            widths[column + 1] = pair - widths[column]
            controls.apply(widths)
        }

        override func mouseUp(with event: NSEvent) {
            controls?.drag = nil
            controls?.guide.isHidden = true
            controls?.widthLabel.isHidden = true
            controls?.onChange?()
        }
    }
}
