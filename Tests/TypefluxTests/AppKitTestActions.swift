import AppKit
import Testing
import CoreFoundation

/// Dispatch native actions without starting AppKit's mouse or menu tracking loops.
@MainActor
enum AppKitTestActions {
    static func press(_ control: NSControl) throws {
        guard control.isEnabled else { return }
        try #require(!(control is NSPopUpButton), "Select a menu item instead of tracking a pop-up button")
        if control.action == nil {
            try SettingsBehaviorTestSupport.pressThroughAccessibility(control)
            return
        }
        if let button = control as? NSButton {
            if let cell = button.cell as? NSButtonCell, !cell.showsStateBy.isEmpty {
                button.setNextState()
            }
        } else if let toggle = control as? NSSwitch {
            toggle.state = toggle.state == .on ? .off : .on
        }
        try dispatch(control)
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
        let handled = window.performKeyEquivalent(with: event)
        for _ in 0 ..< 3 { _ = CFRunLoopRunInMode(.defaultMode, 0, true) }
        return handled
    }

    @discardableResult
    static func selectMenuItem(_ title: String, using button: NSPopUpButton) async throws -> NSControl.StateValue {
        try #require(button.isEnabled)
        // SwiftUI builds pull-down contents in response to these native notifications, before menu tracking.
        NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: button)
        if let cell = button.cell {
            NotificationCenter.default.post(name: NSPopUpButtonCell.willPopUpNotification, object: cell)
        }
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
            try action.press()
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
        -> (item: NSMenuItem, action: SettingsBehaviorTestSupport.Element?)? {
        for item in menu.items {
            if let view = item.view {
                view.layoutSubtreeIfNeeded()
                if let action = SettingsBehaviorTestSupport.elements(in: view).first(where: {
                    $0.label == title && $0.role == NSAccessibility.Role.button.rawValue
                }) {
                    return (item, action)
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
