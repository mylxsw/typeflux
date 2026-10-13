import AppKit
import Testing

@MainActor
extension SettingsBehaviorTestSupport.Element {
    func press() throws {
        // Native mouse/AX clicks enter AppKit tracking loops that can stop the test runner's outer run loop.
        _ = try #require(!(object is NSPopUpButton) && !((object as? NSControl)?.cell is NSPopUpButtonCell),
                         "Select menu items without starting menu tracking")
        if let button = object as? NSButton {
            try pressButton(button)
            return
        }
        if let cell = object as? NSButtonCell {
            try pressCell(cell)
            return
        }
        if let control = object as? NSSwitch {
            try pressSwitch(control)
            return
        }
        if let control = object as? NSControl {
            if let cell = control.cell as? NSButtonCell {
                try pressCell(cell, in: control)
            } else {
                try dispatch(control)
            }
            return
        }
        if let item = object as? NSMenuItem {
            guard item.isEnabled else { return }
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            return
        }
        if try pressNativeButton() || pressNativeSegment() || pressNativeSwitch() { return }
        // SwiftUI proxies need not expose a native control or action. Keep the verified AX/runloop drain.
        _ = try #require(!(object is NSCell), "A native cell must dispatch through its owning control")
        SettingsBehaviorTestSupport.pressThroughAccessibility(object)
    }

    private func dispatch(_ control: NSControl) throws {
        if let window { _ = try #require(control.window === window, "The control must belong to the tested window") }
        guard control.isEnabled else { return }
        guard let action = control.action else {
            SettingsBehaviorTestSupport.pressThroughAccessibility(control)
            return
        }
        #expect(NSApp.sendAction(action, to: control.target, from: control),
                "The native control must dispatch its action: \(label)")
    }

    private func pressButton(_ button: NSButton) throws {
        _ = try #require(!(button is NSPopUpButton), "Select menu items without starting menu tracking")
        if let window { _ = try #require(button.window === window) }
        guard button.isEnabled else { return }
        guard button.action != nil else {
            SettingsBehaviorTestSupport.pressThroughAccessibility(button)
            return
        }
        // Native state-display flags survive missing or overridden AX roles; momentary buttons have none.
        if button.accessibilityRole() == .radioButton {
            button.state = .on
        } else if let cell = button.cell as? NSButtonCell, !cell.showsStateBy.isEmpty {
            button.setNextState()
        }
        try dispatch(button)
    }

    private func pressCell(_ cell: NSButtonCell) throws {
        if let button = cell.controlView as? NSButton {
            try pressButton(button)
            return
        }
        if let control = cell.controlView as? NSControl, !(control is NSMatrix) {
            try pressCell(cell, in: control)
            return
        }
        let matrix = try #require(cell.controlView as? NSMatrix, "The button cell must have an owned control")
        if let window { _ = try #require(matrix.window === window) }
        guard matrix.isEnabled, cell.isEnabled else { return }
        let index = try #require(matrix.cells.firstIndex { $0 === cell })
        let columns = matrix.numberOfColumns
        _ = try #require(columns > 0)
        matrix.selectCell(atRow: index / columns, column: index % columns)
        let action = try #require(cell.action ?? matrix.action)
        let target = cell.action != nil ? cell.target : matrix.target
        #expect(NSApp.sendAction(action, to: target, from: matrix))
    }

    private func pressCell(_ cell: NSButtonCell, in control: NSControl) throws {
        if let window { _ = try #require(control.window === window) }
        guard control.isEnabled, cell.isEnabled else { return }
        guard let action = control.action ?? cell.action else {
            SettingsBehaviorTestSupport.pressThroughAccessibility(control)
            return
        }
        if control.accessibilityRole() == .radioButton {
            cell.state = .on
        } else if !cell.showsStateBy.isEmpty {
            cell.setNextState()
        }
        let target = control.action != nil ? control.target : cell.target
        #expect(NSApp.sendAction(action, to: target, from: control))
    }

    private func pressSwitch(_ control: NSSwitch) throws {
        if let window { _ = try #require(control.window === window) }
        guard control.isEnabled else { return }
        control.state = control.state == .on ? .off : .on
        try dispatch(control)
    }

    private var nativeViews: [NSView] {
        guard let window else { return [] }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let roots = (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView].compactMap { $0 }
        return roots.flatMap(descendants).filter { $0.window === window }
    }

    private func matches(_ control: NSControl) -> Bool {
        let candidate = Self(object: control, window: window)
        let identifier = value("accessibilityIdentifier") as? String
        if let identifier, !identifier.isEmpty,
           let nativeIdentifier = candidate.value("accessibilityIdentifier") as? String,
           !nativeIdentifier.isEmpty {
            guard nativeIdentifier == identifier else { return false }
        } else {
            guard !label.isEmpty, candidate.label == label else { return false }
        }
        guard let window, !frame.isEmpty else { return true }
        return window.convertToScreen(control.convert(control.bounds, to: nil)).intersects(frame)
    }

    private func pressNativeButton() throws -> Bool {
        let roles = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue,
                     NSAccessibility.Role.checkBox.rawValue, NSAccessibility.Role.link.rawValue]
        guard roles.contains(role), let button = nativeViews.compactMap({ $0 as? NSButton }).first(where: {
            !($0 is NSPopUpButton) && $0.action != nil && matches($0)
        }) else { return false }
        try pressButton(button)
        return true
    }

    private func pressNativeSegment() throws -> Bool {
        guard [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue].contains(role),
              !label.isEmpty else { return false }
        for control in nativeViews.compactMap({ $0 as? NSSegmentedControl }) {
            if let index = (0 ..< control.segmentCount).first(where: {
                control.label(forSegment: $0) == label || control.toolTip(forSegment: $0) == label
            }) {
                guard control.isEnabled, control.isEnabled(forSegment: index) else { return true }
                control.selectedSegment = index
                try dispatch(control)
                return true
            }
        }
        for matrix in nativeViews.compactMap({ $0 as? NSMatrix }) {
            if let cell = matrix.cells.compactMap({ $0 as? NSButtonCell }).first(where: { $0.title == label }) {
                try pressCell(cell)
                return true
            }
        }
        return false
    }

    private func pressNativeSwitch() throws -> Bool {
        guard role == NSAccessibility.Role.checkBox.rawValue, let window else { return false }
        if let control = nativeViews.compactMap({ $0 as? NSSwitch }).first(where: {
            window.convertToScreen($0.convert($0.bounds, to: nil)).intersects(frame)
        }) {
            try pressSwitch(control)
            return true
        }
        return false
    }
}
