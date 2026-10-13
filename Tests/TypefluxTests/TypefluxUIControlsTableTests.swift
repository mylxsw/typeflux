import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxUI

@Suite("TypefluxUI native content table", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUIControlsTableTests {
    @Test func `table sorts selects and alternates rows natively`() async throws {
        let rows = [TypefluxGalleryTable.Row(id: 0, term: "Zeta", uses: 1),
                    TypefluxGalleryTable.Row(id: 1, term: "Alpha", uses: 2)]
        var selected = Set<Int>()
        var sortOrder = [KeyPathComparator(\TypefluxGalleryTable.Row.term)]
        let table = TypefluxTable(rows, selection: Binding(get: { selected }, set: { selected = $0 }),
                                  sortOrder: Binding(get: { sortOrder }, set: { sortOrder = $0 })) {
            TableColumn("Term", value: \TypefluxGalleryTable.Row.term) { row in
                TypefluxTableCell(rowID: row.id) { Text(row.term) }
            }
        }.frame(height: 180)
        try await SettingsBehaviorTestSupport.withWindow(table.padding(24), width: 640, height: 400) { _, host in
            try await Task.sleep(for: .milliseconds(100))
            let native = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
            #expect(native.numberOfRows == 2)
            #expect(native.usesAlternatingRowBackgroundColors)
            let first = try #require(native.view(atColumn: 0, row: 0, makeIfNecessary: true))
            #expect(SettingsBehaviorTestSupport.contains("Alpha", in: first))
            native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try await SettingsBehaviorTestSupport.wait { selected == [1] }
            let original = native.sortDescriptors
            let descriptor = try #require(original.first?.reversedSortDescriptor as? NSSortDescriptor)
            native.sortDescriptors = [descriptor]
            native.dataSource?.tableView?(native, sortDescriptorsDidChange: original)
            try await SettingsBehaviorTestSupport.wait { sortOrder.first?.order == .reverse }
        }
        #expect(selected == [1])
        #expect(sortOrder.first?.order == .reverse)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
