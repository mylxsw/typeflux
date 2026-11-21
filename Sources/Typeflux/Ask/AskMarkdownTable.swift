import AppKit
import Markdown

/// Native text table cells keep wrapping, selection and copying in the transcript's text storage.
/// The table draws as on the design board: one rounded hairline frame, a tinted
/// header row and horizontal rules between rows, with no vertical rules.
struct AskMarkdownTable {
    static let corner: CGFloat = 8
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 7
    static let toolbarSpace: CGFloat = 24

    private let table: AskTextTable

    private let sizeColumns: Set<Int>

    init(rows: [any Markup], columnCount: Int) {
        var preferred = Array(repeating: CGFloat(64), count: columnCount)
        var sizes = Set<Int>()
        for (rowIndex, row) in rows.enumerated() {
            for (column, node) in row.children.enumerated() where column < columnCount {
                guard let cell = node as? Markdown.Table.Cell else { continue }
                let text = cell.plainText
                let font = column == 0 ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                                      : NSFont.systemFont(ofSize: 13.5)
                let width = (String(text.prefix(100)) as NSString).size(withAttributes: [.font: font]).width
                preferred[column] = max(preferred[column], min(560, width + 2 * Self.horizontalPadding))
                if rowIndex == 0, ["大小", "文件大小", "檔案大小", "size", "file size", "サイズ", "크기"].contains(text.lowercased()) {
                    sizes.insert(column)
                }
            }
        }
        sizeColumns = sizes
        table = AskTextTable()
        table.rowCount = rows.count
        let total = preferred.reduce(0, +)
        table.automaticWidths = preferred.map { 100 * $0 / total }
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
    }

    func attributes(
        row: Int, column: Int, alignment: Table.ColumnAlignment?, inherited: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let block = Self.cell(table: table, row: row, column: column, width: table.automaticWidths[column])
        let style = (inherited[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.lineSpacing = 4
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        style.tabStops = []
        switch alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case nil where sizeColumns.contains(column): style.alignment = .right
        default: style.alignment = .left
        }
        var attributes = inherited
        attributes[.paragraphStyle] = style
        if row == 0 {
            attributes[.font] = NSFont.systemFont(ofSize: 12, weight: .semibold)
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        } else if column == 0, table.numberOfColumns > 1 {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        } else {
            attributes[.font] = NSFont.systemFont(ofSize: 13.5)
        }
        return attributes
    }

    static func cell(table: NSTextTable, row: Int, column: Int, width: CGFloat) -> AskTableCellBlock {
        let block = AskTableCellBlock(
            table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1
        )
        block.setContentWidth(width,
                              type: .percentageValueType)
        block.setWidth(AskMarkdownTable.horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(AskMarkdownTable.horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
        // A large top margin on NSTextTable also subtracts from its available width.
        // Reserve the action strip in header padding and paint below it.
        block.setWidth(verticalPadding + (row == 0 ? toolbarSpace : 0),
                       type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(AskMarkdownTable.verticalPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
        if row == 0 {
            block.backgroundColor = AskTableCellBlock.headerFill
        }
        return block
    }
}

/// A table that knows its row count, so each cell can tell whether it closes the frame.
final class AskTextTable: NSTextTable {
    var rowCount = 1
    var automaticWidths: [CGFloat] = []
}

/// One cell of `AskMarkdownTable`. It draws its share of the table's frame:
/// the outer edges it sits on (rounded at the table's corners), the header
/// tint, and the rule under its row.
final class AskTableCellBlock: NSTextTableBlock {
    static let headerFill = NSColor(name: "AskTableHeader") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.03)
    }
    static let rule = NSColor(name: "AskTableRule") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.09)
    }

    struct Edges: Equatable {
        var top, bottom, left, right: Bool
    }

    var edges: Edges {
        let rows = (table as? AskTextTable)?.rowCount ?? 1
        return Edges(top: startingRow == 0, bottom: startingRow + rowSpan >= rows,
                     left: startingColumn == 0, right: startingColumn + columnSpan >= table.numberOfColumns)
    }

    /// The corner radii a cell draws: only the table's own four corners round.
    struct Corners: Equatable {
        var topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat

        init(edges: Edges, radius: CGFloat) {
            topLeft = edges.top && edges.left ? radius : 0
            topRight = edges.top && edges.right ? radius : 0
            bottomLeft = edges.bottom && edges.left ? radius : 0
            bottomRight = edges.bottom && edges.right ? radius : 0
        }
    }

    /// The cell outline with only the table's own corners rounded.
    static func outline(_ rect: NSRect, edges: Edges, radius: CGFloat) -> NSBezierPath {
        let corner = Corners(edges: edges, radius: radius)
        let path = NSBezierPath()
        // The text view is flipped: minY is the visual top.
        let topLeft = NSPoint(x: rect.minX, y: rect.minY), topRight = NSPoint(x: rect.maxX, y: rect.minY)
        let bottomLeft = NSPoint(x: rect.minX, y: rect.maxY), bottomRight = NSPoint(x: rect.maxX, y: rect.maxY)
        path.move(to: NSPoint(x: rect.minX + corner.topLeft, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - corner.topRight, y: rect.minY))
        path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + corner.topRight),
                   controlPoint1: topRight, controlPoint2: topRight)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - corner.bottomRight))
        path.curve(to: NSPoint(x: rect.maxX - corner.bottomRight, y: rect.maxY),
                   controlPoint1: bottomRight, controlPoint2: bottomRight)
        path.line(to: NSPoint(x: rect.minX + corner.bottomLeft, y: rect.maxY))
        path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - corner.bottomLeft),
                   controlPoint1: bottomLeft, controlPoint2: bottomLeft)
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + corner.topLeft))
        path.curve(to: NSPoint(x: rect.minX + corner.topLeft, y: rect.minY),
                   controlPoint1: topLeft, controlPoint2: topLeft)
        path.close()
        return path
    }

    /// The strokes this cell owns: its row's bottom rule, plus the outer edges it touches.
    static func strokes(_ rect: NSRect, edges: Edges, radius: CGFloat) -> NSBezierPath {
        let corner = Corners(edges: edges, radius: radius)
        let path = NSBezierPath()
        func segment(_ start: NSPoint, _ end: NSPoint) {
            path.move(to: start)
            path.line(to: end)
        }
        func arc(from start: NSPoint, via control: NSPoint, to end: NSPoint) {
            path.move(to: start)
            path.curve(to: end, controlPoint1: control, controlPoint2: control)
        }
        if edges.top {
            segment(NSPoint(x: rect.minX + corner.topLeft, y: rect.minY),
                    NSPoint(x: rect.maxX - corner.topRight, y: rect.minY))
        }
        segment(NSPoint(x: rect.minX + corner.bottomLeft, y: rect.maxY),
                NSPoint(x: rect.maxX - corner.bottomRight, y: rect.maxY))
        if edges.left {
            segment(NSPoint(x: rect.minX, y: rect.minY + corner.topLeft),
                    NSPoint(x: rect.minX, y: rect.maxY - corner.bottomLeft))
        }
        if edges.right {
            segment(NSPoint(x: rect.maxX, y: rect.minY + corner.topRight),
                    NSPoint(x: rect.maxX, y: rect.maxY - corner.bottomRight))
        }
        if corner.topLeft > 0 {
            arc(from: NSPoint(x: rect.minX, y: rect.minY + corner.topLeft), via: rect.origin,
                to: NSPoint(x: rect.minX + corner.topLeft, y: rect.minY))
        }
        if corner.topRight > 0 {
            arc(from: NSPoint(x: rect.maxX - corner.topRight, y: rect.minY),
                via: NSPoint(x: rect.maxX, y: rect.minY),
                to: NSPoint(x: rect.maxX, y: rect.minY + corner.topRight))
        }
        if corner.bottomRight > 0 {
            arc(from: NSPoint(x: rect.maxX, y: rect.maxY - corner.bottomRight),
                via: NSPoint(x: rect.maxX, y: rect.maxY),
                to: NSPoint(x: rect.maxX - corner.bottomRight, y: rect.maxY))
        }
        if corner.bottomLeft > 0 {
            arc(from: NSPoint(x: rect.minX + corner.bottomLeft, y: rect.maxY),
                via: NSPoint(x: rect.minX, y: rect.maxY),
                to: NSPoint(x: rect.minX, y: rect.maxY - corner.bottomLeft))
        }
        return path
    }

    func visibleFrame(_ rect: NSRect) -> NSRect {
        guard startingRow == 0 else { return rect }
        return rect.divided(atDistance: AskMarkdownTable.toolbarSpace, from: .minYEdge).remainder
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        // Half a point in, so hairlines on the edges stay crisp and inside the frame.
        let rect = visibleFrame(frameRect).insetBy(dx: 0.25, dy: 0.25)
        let edges = edges
        if startingRow == 0 {
            Self.headerFill.setFill()
            Self.outline(rect, edges: edges, radius: AskMarkdownTable.corner).fill()
        }
        Self.rule.setStroke()
        let strokes = Self.strokes(rect, edges: edges, radius: AskMarkdownTable.corner)
        strokes.lineWidth = 1 / max(1, controlView?.window?.backingScaleFactor ?? 2)
        strokes.stroke()
    }
}
