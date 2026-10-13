import AppKit
import Testing
@testable import Typeflux

@MainActor
enum AskNotesToolbarTestSupport {
    static func chooseMode(_ mode: AskNotesViewModel.Mode, in window: NSWindow) throws {
        try choose("ask.notes.mode." + mode.rawValue, in: window)
    }

    static func choose(_ identifier: String, in window: NSWindow) throws {
        let button = try #require(button(in: window), "Missing the owned native More control")
        #expect(button.isEnabled && button.window === window)
        let menu = try #require(button.menu)
        let index = try #require(menu.items.firstIndex { $0.identifier?.rawValue == identifier },
                                 "Missing eagerly built menu item \(identifier): \(menu.items.map(\.title))")
        let item = menu.items[index]
        try #require(item.isEnabled && !item.isHidden)
        #expect(item.target is AskNotesMoreMenu.Coordinator)
        #expect(item.action == #selector(AskNotesMoreMenu.Coordinator.activateItem(_:)))
        menu.performActionForItem(at: index)
    }

    static func button(in window: NSWindow) -> NSPopUpButton? {
        func find(_ view: NSView) -> NSPopUpButton? {
            if let owned = view as? AskNotesMoreMenu.ToolbarView, owned.button.window === window {
                return owned.button
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.toolbar?.items.compactMap(\.view).lazy.compactMap(find).first
    }
}
