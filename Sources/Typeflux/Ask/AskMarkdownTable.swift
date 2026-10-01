import AppKit
import Markdown

/// Native text table cells keep wrapping, selection and copying in the transcript's text storage.
struct AskMarkdownTable {
    private let table: NSTextTable

    init(columnCount: Int) {
        table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
    }

    func attributes(
        row: Int, column: Int, alignment: Table.ColumnAlignment?, inherited: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let block = NSTextTableBlock(
            table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1
        )
        block.setContentWidth(100 / CGFloat(table.numberOfColumns), type: .percentageValueType)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        block.verticalAlignment = .top
        if row == 0 {
            block.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.12)
        }
        let style = (inherited[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.paragraphSpacing = 0
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        switch alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        default: style.alignment = .left
        }
        var attributes = inherited
        attributes[.paragraphStyle] = style
        if row == 0 {
            attributes[.font] = NSFont.systemFont(ofSize: 14, weight: .semibold)
        }
        return attributes
    }
}
