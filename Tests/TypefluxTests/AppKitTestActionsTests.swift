import AppKit
import SwiftUI
import Testing
@testable import TypefluxUI

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AppKitTestActionsTests {
    @Test func buttonActionsSendTheOriginalSenderWithoutTrackingOrActivation() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let button = NontrackingButton(title: "Action", target: recorder, action: #selector(Recorder.record))
        for _ in 0 ..< 2 { try SettingsBehaviorTestSupport.Element(object: button).press() }
        #expect(recorder.senders.count == 2)
        #expect(recorder.senders.allSatisfy { $0 === button })
        #expect(button.trackingCalls == 0)
        button.isEnabled = false
        try AppKitTestActions.press(button)
        #expect(recorder.senders.count == 2)
    }

    @Test func controlsWithoutNativeActionsFailWithoutStartingAccessibilityTracking() {
        let button = NontrackingButton(title: "SwiftUI proxy", target: nil, action: nil)
        #expect(throws: (any Error).self) { try AppKitTestActions.press(button) }
        #expect(throws: (any Error).self) { try SettingsBehaviorTestSupport.Element(object: button).press() }
        #expect(button.trackingCalls == 0)
    }

    @Test func checkboxAndSwitchStateChangesPrecedeTheirActions() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let checkbox = NontrackingButton(title: "Checkbox", target: recorder, action: #selector(Recorder.record))
        checkbox.setButtonType(.switch)
        let toggle = NSSwitch()
        toggle.target = recorder
        toggle.action = #selector(Recorder.record)
        for control in [checkbox as NSControl, toggle] {
            try AppKitTestActions.press(control)
            try AppKitTestActions.press(control)
        }
        #expect(recorder.states == [.on, .off, .on, .off])
        #expect(checkbox.trackingCalls == 0)
    }

    @Test func keyboardActionsStayInTheirOwnedWindowWithoutTracking() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let windows = (0 ..< 2).map { _ in
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                     styleMask: .titled, backing: .buffered, defer: false)
        }
        defer { windows.forEach { $0.contentView = nil; $0.close() } }
        let buttons = windows.map { window in
            window.isReleasedWhenClosed = false
            let button = NontrackingButton(title: "Action", target: recorder, action: #selector(Recorder.record))
            button.keyEquivalent = "k"
            button.keyEquivalentModifierMask = .command
            window.contentView = button
            return button
        }
        let window = try #require(windows.first)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: "k", charactersIgnoringModifiers: "k",
                                                 isARepeat: false, keyCode: 40))
        #expect(try AppKitTestActions.keyEquivalent(event, in: window))
        #expect(recorder.senders.count == 1)
        #expect(recorder.senders.first === buttons.first)
        #expect(buttons.allSatisfy { $0.trackingCalls == 0 })
    }

    @Test func radioCellsUpdateTheirMatrixSelectionBeforeDispatch() throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let prototype = NSButtonCell()
        prototype.setButtonType(.radio)
        let matrix = NSMatrix(frame: .zero, mode: .radioModeMatrix, prototype: prototype,
                              numberOfRows: 2, numberOfColumns: 1)
        matrix.target = recorder
        matrix.action = #selector(Recorder.record)
        let cell = try #require(matrix.cell(atRow: 1, column: 0))
        try AppKitTestActions.selectCell(cell, in: matrix)
        #expect(matrix.selectedCell() === cell)
        #expect(recorder.senders.count == 1)
        #expect(recorder.senders.first === matrix)
    }

    @Test func menuItemActionsDispatchAfterUpdatingLazyContentsWithoutOpeningAMenu() async throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let delegate = MenuDelegate(recorder: recorder)
        menu.delegate = delegate
        button.menu = menu
        let state = try await AppKitTestActions.selectMenuItem("Action", using: button)
        #expect(state == .on)
        #expect(delegate.updates > 0)
        #expect(delegate.opens == 0)
        #expect(recorder.senders.count == 1)
        #expect(recorder.senders.first is NSMenuItem)
    }

    @Test func popupSelectionDispatchesTheControlWhenTheItemHasNoAction() async throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: ["Automatic", "Manual"])
        button.menu?.autoenablesItems = false
        button.target = recorder
        button.action = #selector(Recorder.record)
        try await AppKitTestActions.selectMenuItem("Manual", using: button)
        #expect(button.titleOfSelectedItem == "Manual")
        #expect(recorder.senders.count == 1)
        #expect(recorder.senders.first === button)
    }

    @Test(arguments: [false, true])
    func pullDownNotificationsPopulateTheCurrentMenuBeforeDispatch(cellNotification: Bool) async throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        let factory = PopUpContents(button: button, recorder: recorder)
        let name = cellNotification ? NSPopUpButtonCell.willPopUpNotification : NSPopUpButton.willPopUpNotification
        let source: AnyObject = cellNotification ? try #require(button.cell) : button
        NotificationCenter.default.addObserver(factory, selector: #selector(PopUpContents.prepareMenu),
                                               name: name, object: source)
        defer { NotificationCenter.default.removeObserver(factory) }
        try await AppKitTestActions.selectMenuItem("Action", using: button)
        #expect(factory.preparations == 1)
        #expect(recorder.senders.count == 1)
        #expect(recorder.senders.first is NSMenuItem)
    }

    @Test func delayedMenuContentsBalancePreparationWithoutTracking() async throws {
        _ = NSApplication.shared
        let recorder = Recorder()
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let delegate = MenuDelegate(recorder: recorder)
        delegate.preparesOnOpen = true
        menu.delegate = delegate
        button.menu = menu
        try await AppKitTestActions.selectMenuItem("Action", using: button)
        #expect(delegate.opens == 1)
        #expect(delegate.closes == 1)
        #expect(recorder.senders.count == 1)
    }

    @MainActor private final class Recorder: NSObject {
        var senders: [AnyObject] = []
        var states: [NSControl.StateValue] = []
        @objc func record(_ sender: AnyObject) {
            senders.append(sender)
            if let button = sender as? NSButton { states.append(button.state) }
            if let toggle = sender as? NSSwitch { states.append(toggle.state) }
        }
    }

    @MainActor private final class NontrackingButton: NSButton {
        var trackingCalls = 0
        override func performClick(_: Any?) { trackingCalls += 1 }
        override func mouseDown(with _: NSEvent) { trackingCalls += 1 }
        override func accessibilityPerformPress() -> Bool { trackingCalls += 1; return false }
    }

    @MainActor private final class PopUpContents: NSObject {
        let button: NSPopUpButton
        let recorder: Recorder
        var preparations = 0
        init(button: NSPopUpButton, recorder: Recorder) { self.button = button; self.recorder = recorder }
        @objc func prepareMenu(_: Notification) {
            preparations += 1
            let menu = NSMenu()
            menu.autoenablesItems = false
            let item = NSMenuItem(title: "Action", action: #selector(Recorder.record), keyEquivalent: "")
            item.target = recorder
            menu.addItem(item)
            button.menu = menu
        }
    }

    @MainActor private final class MenuDelegate: NSObject, NSMenuDelegate {
        let recorder: Recorder
        var updates = 0
        var opens = 0
        var closes = 0
        var preparesOnOpen = false
        init(recorder: Recorder) { self.recorder = recorder }
        func menuNeedsUpdate(_ menu: NSMenu) {
            updates += 1
            guard !preparesOnOpen || opens > 0 else { return }
            menu.removeAllItems()
            let item = NSMenuItem(title: "Action", action: #selector(Recorder.record), keyEquivalent: "")
            item.target = recorder
            item.state = .on
            menu.addItem(item)
        }
        func menuWillOpen(_: NSMenu) { opens += 1 }
        func menuDidClose(_: NSMenu) { closes += 1 }
    }
}
