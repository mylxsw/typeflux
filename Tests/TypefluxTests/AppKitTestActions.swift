import AppKit
import Testing
@testable import TypefluxUI

/// Dispatch native actions without starting AppKit's mouse or menu tracking loops.
@MainActor
enum AppKitTestActions {
    static func press(_ control: NSControl) throws {
        guard control.isEnabled else { return }
        try #require(!(control is NSPopUpButton), "Select a menu item instead of tracking a pop-up button")
        if control.action == nil {
            let window = try #require(control.window, "A SwiftUI control must belong to its hosted window")
            let frame = control.convert(control.bounds, to: nil)
            try #require(invokeSwiftUIAction(at: NSPoint(x: frame.midX, y: frame.midY), in: window),
                         "Missing SwiftUI action at the control's frame")
            return
        }
        if let button = control as? NSButton {
            if button.accessibilityRole() == .radioButton {
                button.state = .on
            } else if let cell = button.cell as? NSButtonCell, cell.showsStateBy.rawValue != 0 {
                button.setNextState()
            }
        } else if let toggle = control as? NSSwitch {
            toggle.state = toggle.state == .on ? .off : .on
        }
        try dispatch(control)
    }

    static func invokeSwiftUIAction(at point: NSPoint, in window: NSWindow) -> Bool {
        func views(in view: NSView) -> [TypefluxActionBridge.ActionView] {
            (view as? TypefluxActionBridge.ActionView).map { [$0] } ?? view.subviews.flatMap(views)
        }
        let roots = [window.contentView?.superview ?? window.contentView].compactMap { $0 }
            + (window.toolbar?.items.compactMap(\.view) ?? [])
        let actions = roots.flatMap(views).filter {
            $0.window === window && $0.convert($0.bounds, to: nil).contains(point)
        }.sorted { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        return actions.first?.invoke() ?? false
    }

    static func dispatch(_ control: NSControl) throws {
        guard control.isEnabled else { return }
        let action = try #require(control.action, "Missing native control action")
        #expect(NSApp.sendAction(action, to: control.target, from: control))
    }

    static func selectCell(_ cell: NSCell, in matrix: NSMatrix) throws {
        guard matrix.isEnabled, cell.isEnabled else { return }
        for row in 0 ..< matrix.numberOfRows {
            for column in 0 ..< matrix.numberOfColumns where matrix.cell(atRow: row, column: column) === cell {
                matrix.selectCell(atRow: row, column: column)
                try dispatch(matrix)
                return
            }
        }
        try #require(false, "The selected cell must belong to its matrix")
    }

    static func keyEquivalent(_ event: NSEvent, in window: NSWindow) throws -> Bool {
        let flags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let roots = [window.contentView].compactMap { $0 } + (window.toolbar?.items.compactMap(\.view) ?? [])
        if let button = roots.flatMap(buttons).first(where: {
            !$0.keyEquivalent.isEmpty && $0.keyEquivalent.lowercased() == characters
                && $0.keyEquivalentModifierMask.intersection(flags) == event.modifierFlags.intersection(flags)
        }) {
            guard button.isEnabled else { return false }
            try press(button)
            return true
        }
        // SwiftUI shortcuts can belong to the hosting responder instead of an NSButton.
        return window.performKeyEquivalent(with: event)
    }

    @discardableResult
    static func selectMenuItem(_ title: String, using button: NSPopUpButton) async throws -> NSControl.StateValue {
        try #require(button.isEnabled)
        let menu = try #require(button.menu)
        // Populate SwiftUI's lazy menu through its delegate, without opening it.
        menu.update()
        menu.delegate?.menuNeedsUpdate?(menu)
        var prepared = false
        defer { if prepared { menu.delegate?.menuDidClose?(menu) } }
        let deadline = ContinuousClock.now + .seconds(1)
        while menuEntry(title, in: menu) == nil && ContinuousClock.now < deadline {
            if !prepared {
                // SwiftUI can create the item views from its opening callback.
                // Prepare those views without running NSMenu's tracking loop.
                menu.delegate?.menuWillOpen?(menu)
                prepared = true
            }
            try await Task.sleep(for: .milliseconds(10))
            menu.update()
            menu.delegate?.menuNeedsUpdate?(menu)
        }
        let entry = try #require(menuEntry(title, in: menu),
                                "Menu item \(title) missing from \(menu.items.map(\.title))")
        let item = entry.item
        try #require(item.isEnabled && !item.isSeparatorItem)
        let state = item.state
        if let action = entry.action {
            try #require(action.invoke())
            return state
        }
        if item.menu === menu { button.selectItem(at: menu.index(of: item)) }
        if let action = item.action {
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        } else {
            try dispatch(button)
        }
        return state
    }

    private static func menuEntry(_ title: String, in menu: NSMenu)
        -> (item: NSMenuItem, action: TypefluxActionBridge.ActionView?)? {
        for item in menu.items {
            if let view = item.view {
                view.layoutSubtreeIfNeeded()
                if item.title == title || SettingsBehaviorTestSupport.elements(in: view).contains(where: {
                    $0.label == title
                }) {
                    func action(in view: NSView) -> TypefluxActionBridge.ActionView? {
                        (view as? TypefluxActionBridge.ActionView) ?? view.subviews.lazy.compactMap(action).first
                    }
                    if let action = action(in: view) { return (item, action) }
                }
            }
            if item.title == title { return (item, nil) }
            if let submenu = item.submenu {
                submenu.update()
                submenu.delegate?.menuNeedsUpdate?(submenu)
                if let entry = menuEntry(title, in: submenu) { return entry }
            }
        }
        return nil
    }
}
