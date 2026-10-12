import SwiftUI

/// Native selection, sortable headers and alternating rows. Callers supply columns, never table styling.
public struct TypefluxTable<Row: Identifiable, Columns: TableColumnContent>: View
where Columns.TableRowValue == Row, Columns.TableColumnSortComparator == KeyPathComparator<Row> {
    private let rows: [Row]
    @State private var hoverState = TypefluxTableHoverState()
    @Binding private var selection: Set<Row.ID>
    @Binding private var sortOrder: [KeyPathComparator<Row>]
    private let columns: Columns

    public init(_ rows: [Row], selection: Binding<Set<Row.ID>>, sortOrder: Binding<[KeyPathComparator<Row>]>,
                @TableColumnBuilder<Row, KeyPathComparator<Row>> columns: () -> Columns) {
        self.rows = rows
        _selection = selection
        _sortOrder = sortOrder
        self.columns = columns()
    }

    public var body: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) { columns }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .environment(\.typefluxTableHoverState, $hoverState)
    }
}
