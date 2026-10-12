import SwiftUI

struct TypefluxGalleryTable: View {
    struct Row: Identifiable {
        let id: Int
        let term: String
        let uses: Int
    }

    @State private var rows = [Row(id: 0, term: "Typeflux", uses: 214), Row(id: 1, term: "Liquid Glass", uses: 37),
                               Row(id: 2, term: "PGVector", uses: 19), Row(id: 3, term: "SwiftUI", uses: 88)]
    @State private var selection: Set<Int> = [0]
    @State private var sortOrder = [KeyPathComparator(\Row.term)]

    var body: some View {
        TypefluxTable(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Term", value: \Row.term) { row in
                TypefluxTableCell(rowID: row.id) { Text(row.term) }
            }
            TableColumn("Uses", value: \Row.uses) { row in
                TypefluxTableCell(rowID: row.id) { Text(row.uses, format: .number).monospacedDigit() }
            }
            TableColumn("Actions") { row in
                TypefluxTableActions(rowID: row.id, selected: selection.contains(row.id)) {
                    TypefluxIconButton("Delete \(row.term)", systemImage: "trash", kind: .destructive) {
                        rows.removeAll { $0.id == row.id }
                        selection.remove(row.id)
                    }
                }
            }.width(80)
        }
    }
}
