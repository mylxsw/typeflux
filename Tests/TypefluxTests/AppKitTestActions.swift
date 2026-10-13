import AppKit
import Testing

/// Dispatch native actions without starting AppKit's mouse or menu tracking loops.
@MainActor
enum AppKitTestActions {
    static func press(_ control: NSControl) throws {
        guard control.isEnabled else { return }
        try #require(!(control is NSPopUpButton), "Select a menu item instead of tracking a pop-up button")
        if let button = control as? NSButton {
            switch button.accessibilityRole() {
            case .checkBox: button.state = button.state == .on ? .off : .on
            case .radioButton: button.state = .on
            default: break
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
        return window.performKeyEquivalent(with: event)
    }

    @discardableResult
    static func selectMenuItem(_ title: String, using button: NSPopUpButton) throws -> NSControl.StateValue {
        try #require(button.isEnabled)
        let menu = try #require(button.menu)
        // Populate SwiftUI's lazy menu through its delegate, without opening it.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        let item = try #require(menu.items.first { $0.title == title },
                                "Menu item \(title) missing from \(menu.items.map(\.title))")
        try #require(item.isEnabled && !item.isSeparatorItem)
        let state = item.state
        button.selectItem(at: menu.index(of: item))
        if let action = item.action {
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        } else {
            try dispatch(button)
        }
        return state
    }
}
