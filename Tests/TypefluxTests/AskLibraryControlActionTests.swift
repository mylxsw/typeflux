import AppKit
import Testing

@Suite("Library control action dispatch", .serialized, .exclusiveUIState)
@MainActor
struct AskLibraryControlActionTests {
    @MainActor private final class Recorder: NSObject {
        var senders: [NSControl] = []
        var states: [NSControl.StateValue] = []
        var segments: [Int] = []

        @objc func record(_ sender: NSControl) {
            senders.append(sender)
            if let button = sender as? NSButton { states.append(button.state) }
            if let control = sender as? NSSwitch { states.append(control.state) }
            if let control = sender as? NSSegmentedControl { segments.append(control.selectedSegment) }
        }
    }

    @Test func buttonsAndTheirCellsDispatchOnceWithoutAKeyWindow() throws {
        try withControls { window, content, recorder in
            let button = makeButton(type: .momentaryPushIn, recorder: recorder)
            content.addSubview(button)
            let responder = window.firstResponder
            try SettingsBehaviorTestSupport.Element(object: button, window: window).press()
            let cell = try #require(button.cell as? NSButtonCell)
            try SettingsBehaviorTestSupport.Element(object: cell, window: window).press()
            #expect(recorder.senders.count == 2)
            #expect(recorder.senders.allSatisfy { $0 === button })
            #expect(recorder.states == [.off, .off], "Momentary actions must not advance persistent state")
            #expect(window.firstResponder === responder, "Action dispatch does not need native focus transitions")
        }
    }

    @Test func checkboxAndSwitchActionsObserveTheNewStateAndRespectDisabledControls() throws {
        try withControls { window, content, recorder in
            let button = makeButton(type: .switch, recorder: recorder)
            button.setAccessibilityRole(.button)
            content.addSubview(button)
            let checkbox = SettingsBehaviorTestSupport.Element(object: button, window: window)
            try checkbox.press()
            try checkbox.press()
            button.isEnabled = false
            try checkbox.press()
            #expect(button.state == .off)
            #expect(recorder.states == [.on, .off])

            let control = NSSwitch(frame: NSRect(x: 150, y: 20, width: 50, height: 24))
            control.target = recorder
            control.action = #selector(Recorder.record(_:))
            content.addSubview(control)
            let toggle = SettingsBehaviorTestSupport.Element(object: control, window: window)
            try toggle.press()
            try toggle.press()
            control.isEnabled = false
            try toggle.press()
            #expect(control.state == .off)
            #expect(recorder.states == [.on, .off, .on, .off])
            #expect(recorder.senders.count == 4)
        }
    }

    @Test func matchingAccessibilityProxiesDispatchOnlyToTheOwningWindow() throws {
        try withControls { window, content, recorder in
            try withControls { otherWindow, otherContent, otherRecorder in
                let button = makeButton(type: .momentaryPushIn, recorder: recorder)
                let otherButton = makeButton(type: .momentaryPushIn, recorder: otherRecorder)
                for control in [button, otherButton] { control.setAccessibilityIdentifier("library.copy") }
                content.addSubview(button)
                otherContent.addSubview(otherButton)
                let proxy = NSAccessibilityElement()
                proxy.setAccessibilityRole(.button)
                proxy.setAccessibilityLabel("Copy")
                proxy.setAccessibilityIdentifier("library.copy")
                try SettingsBehaviorTestSupport.Element(object: proxy, window: window).press()
                #expect(recorder.senders.count == 1 && recorder.senders.first === button)
                #expect(otherRecorder.senders.isEmpty)
                #expect(otherWindow.contentView === otherContent)
            }
        }
    }

    @Test func radioButtonsAndMatrixCellsSendTheirSelectedState() throws {
        try withControls { window, content, recorder in
            let radio = makeButton(type: .radio, recorder: recorder)
            radio.setAccessibilityRole(.button)
            content.addSubview(radio)
            try SettingsBehaviorTestSupport.Element(object: radio, window: window).press()
            #expect(recorder.states == [.on])
            let prototype = NSButtonCell(textCell: "Mode")
            prototype.setButtonType(.radio)
            let matrix = NSMatrix(frame: NSRect(x: 150, y: 20, width: 160, height: 50), mode: .radioModeMatrix,
                                  prototype: prototype, numberOfRows: 2, numberOfColumns: 1)
            matrix.target = recorder
            matrix.action = #selector(Recorder.record(_:))
            content.addSubview(matrix)
            let cell = try #require(matrix.cell(atRow: 1, column: 0) as? NSButtonCell)
            cell.controlView = matrix
            try SettingsBehaviorTestSupport.Element(object: cell, window: window).press()
            #expect(matrix.selectedCell() === cell && cell.state == .on)
            #expect(recorder.senders.count == 2 && recorder.senders.last === matrix)
            cell.isEnabled = false
            try SettingsBehaviorTestSupport.Element(object: cell, window: window).press()
            #expect(recorder.senders.count == 2)
        }
    }

    @Test func segmentedProxiesSendTheSelectedSegmentAndLeaveDisabledSegmentsAlone() throws {
        try withControls { window, content, recorder in
            let control = NSSegmentedControl(labels: ["Preview", "Edit", "Split"],
                                             trackingMode: .selectOne, target: recorder,
                                             action: #selector(Recorder.record(_:)))
            control.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
            control.selectedSegment = 0
            content.addSubview(control)
            let proxy = NSAccessibilityElement()
            proxy.setAccessibilityRole(.radioButton)
            proxy.setAccessibilityLabel("Split")
            let split = SettingsBehaviorTestSupport.Element(object: proxy, window: window)
            try split.press()
            #expect(recorder.segments == [2])
            control.selectedSegment = 0
            control.setEnabled(false, forSegment: 2)
            try split.press()
            #expect(control.selectedSegment == 0)
            #expect(recorder.segments == [2])
        }
    }

    @Test func mixedCheckboxStateAdvancesBeforeEachActionWithoutAnAXCheckboxRole() throws {
        try withControls { window, content, recorder in
            let button = makeButton(type: .switch, recorder: recorder)
            button.setAccessibilityRole(.button)
            button.allowsMixedState = true
            button.state = .mixed
            content.addSubview(button)
            let checkbox = SettingsBehaviorTestSupport.Element(object: button, window: window)
            for _ in 0 ..< 3 { try checkbox.press() }
            #expect(recorder.states == [.on, .off, .mixed])
            #expect(recorder.senders.count == 3 && recorder.senders.allSatisfy { $0 === button })
        }
    }

    private func makeButton(type: NSButton.ButtonType, recorder: Recorder) -> NSButton {
        let button = NSButton(title: "Copy", target: recorder, action: #selector(Recorder.record(_:)))
        button.setButtonType(type)
        // These fixtures do not draw or become key; establish the cell owner explicitly.
        button.cell?.controlView = button
        button.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        return button
    }

    private func withControls(_ check: (NSWindow, NSView, Recorder) throws -> Void) throws {
        TypefluxTestApplicationEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        window.contentView = content
        defer { window.contentView = nil; window.close() }
        try check(window, content, Recorder())
    }
}
