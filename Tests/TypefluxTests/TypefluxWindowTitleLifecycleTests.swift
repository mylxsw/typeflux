import AppKit
import Testing
@testable import TypefluxUI

@Suite("Window title lifecycle", .exclusiveUIState)
@MainActor
struct TypefluxWindowTitleLifecycleTests {
    private final class ToolbarDelegate: NSObject, NSToolbarDelegate {
        let item = NSToolbarItemGroup(itemIdentifier: .init("add"))

        func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            [item.itemIdentifier]
        }

        func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            [item.itemIdentifier]
        }

        func toolbar(_: NSToolbar, itemForItemIdentifier _: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
            item
        }
    }

    @Test func `primary actions keep priority when native groups have no subitems`() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = ToolbarDelegate()
        delegate.item.label = "Add"
        let toolbar = NSToolbar(identifier: "ActionPriority")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        if !toolbar.items.contains(where: { $0.itemIdentifier == delegate.item.itemIdentifier }) {
            toolbar.insertItem(withItemIdentifier: delegate.item.itemIdentifier, at: 0)
        }
        let view = TypefluxWindowTitleBridge.TitleView()
        view.actionTitles = ["Add"]
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.synchronize()
        #expect(delegate.item.subitems.isEmpty)
        #expect(delegate.item.visibilityPriority == .high)
        delegate.item.visibilityPriority = .user
        view.synchronize()
        #expect(delegate.item.visibilityPriority == .user)
    }

    @Test func `metadata survives toolbar updates and stops after detachment`() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TypefluxWindowTitleBridge.TitleView()
        view.title = "Settings"
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        #expect(window.title == "Settings")
        #expect(window.titleVisibility == .hidden)
        window.titleVisibility = .visible
        window.toolbar = NSToolbar(identifier: "TitleLifecycle")
        try await SettingsBehaviorTestSupport.wait { window.titleVisibility == .hidden }
        view.title = "Account"
        view.synchronize()
        #expect(window.title == "Account")
        window.contentView = nil
        window.titleVisibility = .visible
        try await Task.sleep(for: .milliseconds(80))
        #expect(window.titleVisibility == .visible)
        #expect(window.contentView == nil)
    }
}
