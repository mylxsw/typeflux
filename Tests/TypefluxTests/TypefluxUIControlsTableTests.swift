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

    @Test(arguments: InterfaceStyle.allCases)
    func `fitted tables stripe only real rows and scroll when rows grow`(style: InterfaceStyle) async throws {
        for count in [2, 40] {
            let rows = (0 ..< count).map { TypefluxGalleryTable.Row(id: $0, term: "Term \($0)", uses: $0) }
            let table = TypefluxTable(rows, selection: .constant(Set<Int>()),
                                      sortOrder: .constant([KeyPathComparator(\TypefluxGalleryTable.Row.term)]),
                                      identifier: "fitted.table", fillsAvailableHeight: false) {
                TableColumn("Term", value: \TypefluxGalleryTable.Row.term) { row in
                    TypefluxTableCell(rowID: row.id) { Text(row.term) }
                }
            }.environment(\.interfaceStyle, style)
            try await SettingsBehaviorTestSupport.withWindow(table, width: 640, height: 400) { _, host in
                try await SettingsBehaviorTestSupport.wait {
                    descendants(host).compactMap { $0 as? NSTableView }.first?.numberOfRows == count
                }
                let native = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
                let scroll = try #require(native.enclosingScrollView)
                #expect(native.usesAlternatingRowBackgroundColors)
                if count == 2 {
                    try await SettingsBehaviorTestSupport.wait { scroll.frame.height < 150 }
                    #expect(scroll.frame.height >= native.rect(ofRow: count - 1).maxY)
                } else {
                    #expect(scroll.frame.height <= 400)
                    #expect(native.rect(ofRow: count - 1).maxY > scroll.contentSize.height)
                    native.scrollRowToVisible(count - 1)
                    #expect(NSLocationInRange(count - 1, native.rows(in: native.visibleRect)))
                }
            }
        }
    }
}
