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

    public init(_ rows: [Row], selection: Binding<Set<Row.ID>>, sortOrder: Binding<[KeyPathComparator<Row>]>,
                onDelete: (() -> Void)? = nil, identifier: String = UUID().uuidString,
                @TableColumnBuilder<Row, KeyPathComparator<Row>> columns: () -> Columns) {
        self.rows = rows
        _selection = selection
        _sortOrder = sortOrder
        self.columns = columns()
        self.onDelete = onDelete
        self.identifier = identifier
    }

    public var body: some View {
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
