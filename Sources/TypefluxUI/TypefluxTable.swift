import SwiftUI

/// Native selection, sortable headers and alternating rows. Callers supply columns, never table styling.
public struct TypefluxTable<Row: Identifiable, Columns: TableColumnContent>: View
    where Columns.TableRowValue == Row, Columns.TableColumnSortComparator == KeyPathComparator<Row> {
    private let rows: [Row]
    @State private var hoverState = TypefluxTableHoverState()
    @Binding private var selection: Set<Row.ID>
    @Binding private var sortOrder: [KeyPathComparator<Row>]
    private let columns: Columns
    private let onDelete: (() -> Void)?
    private let identifier: String
    private let stripesEmptyRows: Bool

    public init(_ rows: [Row], selection: Binding<Set<Row.ID>>, sortOrder: Binding<[KeyPathComparator<Row>]>,
                onDelete: (() -> Void)? = nil, identifier: String = UUID().uuidString,
                stripesEmptyRows: Bool = true,
                @TableColumnBuilder<Row, KeyPathComparator<Row>> columns: () -> Columns) {
        self.rows = rows
        _selection = selection
        _sortOrder = sortOrder
        self.columns = columns()
        self.onDelete = onDelete
        self.identifier = identifier
        self.stripesEmptyRows = stripesEmptyRows
    }

    public var body: some View {
        if stripesEmptyRows {
            table
        } else {
            table
                .scrollContentBackground(.hidden)
                .background(TypefluxColor.contentBackground.color)
                .background(TypefluxTableRowBackground(tableIdentifier: identifier)
                    .frame(width: 0, height: 0))
        }
    }

    private var table: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) { columns }
            .tableStyle(.inset(alternatesRowBackgrounds: stripesEmptyRows))
            .environment(\.typefluxTableHoverState, $hoverState)
            .environment(\.typefluxTableStripesEmptyRows, stripesEmptyRows)
            .onDeleteCommand(perform: onDelete)
            .accessibilityIdentifier(identifier)
            .background(TypefluxTableDeleteKey(action: onDelete, tableIdentifier: identifier).frame(
                width: 0,
                height: 0
            ))
    }
}
