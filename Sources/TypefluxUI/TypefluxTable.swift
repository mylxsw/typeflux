import SwiftUI

/// Native selection, sortable headers and alternating rows. Callers supply columns, never table styling.
public struct TypefluxTable<Row: Identifiable, Columns: TableColumnContent>: View
    where Columns.TableRowValue == Row, Columns.TableColumnSortComparator == KeyPathComparator<Row> {
    private let rows: [Row]
    @State private var hoverState = TypefluxTableHoverState()
    @State private var contentHeight: CGFloat = 0
    @Environment(\.interfaceStyle) private var style
    @Binding private var selection: Set<Row.ID>
    @Binding private var sortOrder: [KeyPathComparator<Row>]
    private let columns: Columns
    private let onDelete: (() -> Void)?
    private let identifier: String
    private let fillsAvailableHeight: Bool

    public init(_ rows: [Row], selection: Binding<Set<Row.ID>>, sortOrder: Binding<[KeyPathComparator<Row>]>,
                onDelete: (() -> Void)? = nil, identifier: String = UUID().uuidString,
                fillsAvailableHeight: Bool = true,
                @TableColumnBuilder<Row, KeyPathComparator<Row>> columns: () -> Columns) {
        self.rows = rows
        _selection = selection
        _sortOrder = sortOrder
        self.columns = columns()
        self.onDelete = onDelete
        self.identifier = identifier
        self.fillsAvailableHeight = fillsAvailableHeight
    }

    public var body: some View {
        if fillsAvailableHeight {
            table
        } else {
            GeometryReader { geometry in
                table
                    .background(TypefluxTableContentHeight(height: $contentHeight, rowCount: rows.count,
                                                          identifier: identifier).frame(width: 0, height: 0))
                    .frame(height: min(geometry.size.height, contentHeight > 0 ? contentHeight :
                        CGFloat(rows.count) * TypefluxControlHeight.tableRow.value(for: .liquidGlass)
                            + TypefluxControlHeight.toolbar.value(for: style)))
            }
        }
    }

    private var table: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) { columns }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .environment(\.typefluxTableHoverState, $hoverState)
            .onDeleteCommand(perform: onDelete)
            .accessibilityIdentifier(identifier)
            .background(TypefluxTableDeleteKey(action: onDelete, tableIdentifier: identifier).frame(
                width: 0,
                height: 0
            ))
    }
}
