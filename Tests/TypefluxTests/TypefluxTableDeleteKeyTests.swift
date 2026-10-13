import AppKit
import Testing
@testable import TypefluxUI

@Suite(.exclusiveUIState)
@MainActor
struct TypefluxTableDeleteKeyTests {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in _: NSTableView) -> Int {
            2
        }
    }

    @Test func `delete is scoped to selected table focus and releases its window monitor`() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let rows = Rows()
        let table = makeTable(rows)
        let view = TypefluxTableDeleteKey.KeyView()
        var deletions = 0
        view.action = { deletions += 1 }
        root.addSubview(table)
        root.addSubview(view)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(window.makeFirstResponder(table))
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                          keyCode: code))
        }
        #expect(try view.handle(key(51)))
        #expect(try view.handle(key(117, modifiers: .function)))
        #expect(deletions == 2)
        #expect(try !view.handle(key(51, modifiers: .command)))
        #expect(try !view.handle(key(36)))
        table.deselectAll(nil)
        #expect(try !view.handle(key(51)))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 320, width: 300, height: 60))
        root.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        #expect(try !view.handle(key(51)))
        #expect(window.makeFirstResponder(table))
        let second = NSTableView()
        root.addSubview(second)
        #expect(try !view.handle(key(51)))
        second.removeFromSuperview()
        view.action = nil
        #expect(try !view.handle(key(51)))
        view.action = { deletions += 1 }
        view.removeFromSuperview()
        #expect(try !view.handle(key(51)))
        root.addSubview(view)
        table.removeFromSuperview()
        #expect(try !view.handle(key(51)))
        #expect(deletions == 2)
        view.stop()
    }

    private func makeTable(_ rows: Rows) -> NSTableView {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.addTableColumn(NSTableColumn(identifier: .init("term")))
        table.dataSource = rows
        table.reloadData()
        return table
    }
}
