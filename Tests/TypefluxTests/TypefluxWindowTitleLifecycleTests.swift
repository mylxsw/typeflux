import AppKit
import Testing
@testable import TypefluxUI

@Suite("Window title lifecycle", .exclusiveUIState)
@MainActor
struct TypefluxWindowTitleLifecycleTests {
    private final class FixedItemsDelegate: NSObject, NSToolbarDelegate {
        let catalog: [NSToolbarItem]
        init(_ catalog: [NSToolbarItem]) {
            self.catalog = catalog
            super.init()
        }
        func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { catalog.map(\.itemIdentifier) }
        func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { catalog.map(\.itemIdentifier) }
        func toolbar(_: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? { catalog.first { $0.itemIdentifier == id } }
    }

    @Test func `title follows the native detail divider and moves left after sidebar collapse`() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        split.isVertical = true
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        let detail = NSView(frame: NSRect(x: 221, y: 0, width: 579, height: 600))
        split.addSubview(sidebar)
        split.addSubview(detail)
        let bridge = TypefluxWindowTitleBridge.TitleView()
        bridge.representedWindowTitle = "Settings"
        detail.addSubview(bridge)
        window.contentView = split
        defer { window.contentView = nil; window.close() }
        let title = NSToolbarItem(itemIdentifier: .init(TypefluxWindowTitleBridge.itemIdentifier))
        let separator = NSTrackingSeparatorToolbarItem(identifier: .init("detail.divider"), splitView: split, dividerIndex: 0)
        let action = NSToolbarItem(itemIdentifier: .init("action"))
        let delegate = FixedItemsDelegate([title, separator, action])
        let toolbar = NSToolbar(identifier: "DetailTitleOrder")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        for item in delegate.catalog where !toolbar.items.contains(where: { $0.itemIdentifier == item.itemIdentifier }) {
            toolbar.insertItem(withItemIdentifier: item.itemIdentifier, at: toolbar.items.count)
        }
        bridge.synchronize()
        #expect(toolbar.items.map(\.itemIdentifier) == [separator.itemIdentifier, title.itemIdentifier, action.itemIdentifier])
        sidebar.isHidden = true
        sidebar.frame.size.width = 0
        bridge.synchronize()
        #expect(toolbar.items.first?.itemIdentifier == title.itemIdentifier)
    }
    private final class ToolbarDelegate: NSObject, NSToolbarDelegate {
        let item = NSToolbarItemGroup(itemIdentifier: .init("add"))

        func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { [item.itemIdentifier] }
        func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { [item.itemIdentifier] }
        func toolbar(_: NSToolbar, itemForItemIdentifier _: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? { item }
    }

    @Test func `primary actions retain priority when native groups have no subitems`() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = ToolbarDelegate()
        delegate.item.label = "New word"
        let toolbar = NSToolbar(identifier: "ActionPriority")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        if !toolbar.items.contains(where: { $0.itemIdentifier == delegate.item.itemIdentifier }) {
            toolbar.insertItem(withItemIdentifier: delegate.item.itemIdentifier, at: 0)
        }
        let view = TypefluxWindowTitleBridge.TitleView()
        view.actionTitles = ["New word"]
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.synchronize()
        #expect(delegate.item.subitems.isEmpty)
        #expect(delegate.item.visibilityPriority == .high)
        delegate.item.visibilityPriority = .user
        view.synchronize()
        #expect(delegate.item.visibilityPriority == .user)
    }

    @Test func metadataSurvivesToolbarUpdatesAndStopsAfterDetachment() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TypefluxWindowTitleBridge.TitleView()
        view.representedWindowTitle = "Settings"
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        #expect(window.title == "Settings")
        #expect(window.titleVisibility == .hidden)
        window.title = ""
        try await SettingsBehaviorTestSupport.wait { window.title == "Settings" }
        window.titleVisibility = .visible
        window.toolbar = NSToolbar(identifier: "TitleLifecycle")
        try await SettingsBehaviorTestSupport.wait { window.titleVisibility == .hidden }
        view.representedWindowTitle = "Account"
        view.synchronize()
        #expect(window.title == "Account")
        window.contentView = nil
        window.title = "Detached"
        window.titleVisibility = .visible
        try await Task.sleep(for: .milliseconds(80))
        #expect(window.titleVisibility == .visible)
        #expect(window.title == "Detached", "title observation ends with the hosted view")
        #expect(window.contentView == nil)
    }
}
