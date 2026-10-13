import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxUI

@Suite("TypefluxUI native content table", .serialized, .exclusiveUIState)
@MainActor
struct TypefluxUIControlsTableTests {
    private final class ContentRows: ObservableObject {
        @Published var rows = [TypefluxGalleryTable.Row(id: 0, term: "Alpha", uses: 1),
                               TypefluxGalleryTable.Row(id: 1, term: "Beta", uses: 2)]
    }

    private struct ContentTable: View {
        @ObservedObject var source: ContentRows
        @State private var selection = Set<Int>()
        @State private var order = [KeyPathComparator(\TypefluxGalleryTable.Row.term)]

        var body: some View {
            TypefluxTable(source.rows, selection: $selection, sortOrder: $order, stripesEmptyRows: false) {
                TableColumn("Term", value: \TypefluxGalleryTable.Row.term) { row in
                    TypefluxTableCell(rowID: row.id) { Text(row.term) }
                }
            }
        }
    }

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

    @Test func `content table insertions and deletion preserve a full height viewport`() async throws {
        let source = ContentRows()
        try await SettingsBehaviorTestSupport.withWindow(ContentTable(source: source), width: 400, height: 400) { _, host in
            try await SettingsBehaviorTestSupport.wait {
                descendants(host).compactMap { $0 as? NSTableView }.first?.numberOfRows == 2
            }
            let native = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
            let scroll = try #require(native.enclosingScrollView)
            source.rows.append(contentsOf: [TypefluxGalleryTable.Row(id: 2, term: "Gamma", uses: 3),
                                            TypefluxGalleryTable.Row(id: 3, term: "Zeta", uses: 4)])
            try await SettingsBehaviorTestSupport.wait {
                native.numberOfRows == 4
                    && native.rowView(atRow: 3, makeIfNecessary: false)?.backgroundColor
                    == NSColor.alternatingContentBackgroundColors.last
            }
            #expect(abs(scroll.frame.height - host.bounds.height) < 1)
            #expect(NSLocationInRange(3, native.rows(in: native.visibleRect)))
            source.rows.removeAll()
            try await SettingsBehaviorTestSupport.wait { native.numberOfRows == 0 }
            #expect(abs(scroll.frame.height - host.bounds.height) < 1)
            #expect(!native.usesAlternatingRowBackgroundColors && native.backgroundColor == .clear)
        }
    }

    @Test(arguments: InterfaceStyle.allCases, [400.0, 720.0])
    func `full height content tables keep short and long lists visible at narrow widths`(style: InterfaceStyle,
                                                                                      width: Double) async throws {
        for count in [2, 4, 40] {
            let rows = (0 ..< count).map { TypefluxGalleryTable.Row(id: $0, term: "Term \($0)", uses: $0) }
            let table = TypefluxTable(rows, selection: .constant(Set<Int>()),
                                      sortOrder: .constant([KeyPathComparator(\TypefluxGalleryTable.Row.term)]),
                                      identifier: "content.table", stripesEmptyRows: false) {
                TableColumn("Term", value: \TypefluxGalleryTable.Row.term) { row in
                    TypefluxTableCell(rowID: row.id) { Text(row.term) }
                }.width(600)
            }.environment(\.interfaceStyle, style)
            try await SettingsBehaviorTestSupport.withWindow(table, width: width, height: 400) { _, host in
                try await SettingsBehaviorTestSupport.wait {
                    descendants(host).compactMap { $0 as? NSTableView }.first?.numberOfRows == count
                }
                let native = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
                let scroll = try #require(native.enclosingScrollView)
                try await SettingsBehaviorTestSupport.wait {
                    !native.usesAlternatingRowBackgroundColors && !scroll.drawsBackground
                }
                #expect(abs(scroll.frame.height - host.bounds.height) < 1)
                #expect(!scroll.contentView.drawsBackground)
                #expect(native.backgroundColor == .clear)
                let stripe = try #require(native.rowView(atRow: 1, makeIfNecessary: false))
                try await SettingsBehaviorTestSupport.wait {
                    stripe.backgroundColor == NSColor.alternatingContentBackgroundColors.last
                }
                if count < 40 {
                    #expect(scroll.contentSize.height > native.rect(ofRow: count - 1).maxY)
                    let lastRow = native.rect(ofRow: count - 1)
                    #expect(native.visibleRect.minY <= lastRow.minY)
                    #expect(native.visibleRect.maxY >= lastRow.maxY)
                } else {
                    #expect(scroll.frame.height <= 400)
                    #expect(native.rect(ofRow: count - 1).maxY > scroll.contentSize.height)
                    native.scrollRowToVisible(count - 1)
                    #expect(NSLocationInRange(count - 1, native.rows(in: native.visibleRect)))
                    try await SettingsBehaviorTestSupport.wait {
                        native.rowView(atRow: count - 1, makeIfNecessary: false)?.backgroundColor
                            == NSColor.alternatingContentBackgroundColors.last
                    }
                }
            }
        }
    }
}
