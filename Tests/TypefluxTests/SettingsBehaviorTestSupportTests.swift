import AppKit
import ObjectiveC
import SwiftUI
import Testing

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct SettingsBehaviorTestSupportTests {
    @MainActor
    private final class EventLoopProbe: NSApplication {
        static var calls = 0
        override func nextEvent(matching _: NSEvent.EventTypeMask, until _: Date?,
                                inMode _: RunLoop.Mode, dequeue _: Bool) -> NSEvent? {
            EventLoopProbe.calls += 1
            return nil
        }
    }

    @MainActor
    private final class ButtonCellProbe: NSButtonCell {
        static var calls = 0
        override func performClick(_: Any?) { ButtonCellProbe.calls += 1 }
    }

    @MainActor
    private final class Target: NSObject {
        var senders: [NSControl] = []
        var states: [NSControl.StateValue] = []
        var selectedRows: [Int] = []

        @objc func receive(_ sender: NSControl) {
            senders.append(sender)
            if let button = sender as? NSButton { states.append(button.state) }
            if let control = sender as? NSSwitch { states.append(control.state) }
            if let matrix = sender as? NSMatrix { selectedRows.append(matrix.selectedRow) }
        }
    }

    private struct NativeButton: NSViewRepresentable {
        let button: NSButton
        func makeNSView(context _: Context) -> NSButton { button }
        func updateNSView(_: NSButton, context _: Context) {}
    }

    private struct NativeMatrix: NSViewRepresentable {
        let matrix: NSMatrix
        func makeNSView(context _: Context) -> NSMatrix { matrix }
        func updateNSView(_: NSMatrix, context _: Context) {}
    }

    @Test func `native button dispatches its wired action with the original sender`() throws {
        let target = Target()
        let button = NSButton(title: "Dispatch", target: target, action: #selector(Target.receive(_:)))
        try SettingsBehaviorTestSupport.Element(object: button).press()
        #expect(target.senders.count == 1 && target.senders.first === button)
        #expect(button.action == #selector(Target.receive(_:)))
    }

    @Test func `disabled native buttons and switches do not dispatch or change state`() throws {
        let target = Target()
        let button = NSButton(title: "Disabled", target: target, action: #selector(Target.receive(_:)))
        button.isEnabled = false
        let control = NSSwitch(frame: .zero)
        control.target = target
        control.action = #selector(Target.receive(_:))
        control.state = .off
        control.isEnabled = false
        try SettingsBehaviorTestSupport.Element(object: button).press()
        try SettingsBehaviorTestSupport.Element(object: control).press()
        #expect(target.senders.isEmpty && control.state == .off)
    }

    @Test func `checkbox state changes before its target receives each action`() throws {
        let target = Target()
        let button = NSButton(checkboxWithTitle: "Toggle", target: target, action: #selector(Target.receive(_:)))
        button.state = .off
        try SettingsBehaviorTestSupport.Element(object: button).press()
        try SettingsBehaviorTestSupport.Element(object: button).press()
        #expect(target.states == [.on, .off])
        #expect(target.senders.allSatisfy { $0 === button })
    }

    @Test func `mixed checkbox uses the native three state cycle before dispatch`() throws {
        let target = Target()
        let button = NSButton(checkboxWithTitle: "Mixed", target: target, action: #selector(Target.receive(_:)))
        button.allowsMixedState = true
        button.state = .on
        for _ in 0 ..< 3 { try SettingsBehaviorTestSupport.Element(object: button).press() }
        #expect(target.states == [.off, .mixed, .on])
    }

    @Test func `native radio remains selected on successive actions`() throws {
        let target = Target()
        let button = NSButton(radioButtonWithTitle: "Radio", target: target, action: #selector(Target.receive(_:)))
        button.state = .off
        for _ in 0 ..< 2 { try SettingsBehaviorTestSupport.Element(object: button).press() }
        #expect(target.states == [.on, .on])
    }

    @Test func `wired native button dispatches without clicks or event polling`() async throws {
        let target = Target()
        let button = NSButton(title: "Wired action", target: target, action: #selector(Target.receive(_:)))
        try await TypefluxNavigationTestSupport.withWindow(NativeButton(button: button)) { window, _ in
            #expect(button.window === window)
            try withoutClickEventLoops {
                try SettingsBehaviorTestSupport.Element(object: button, window: window).press()
            }
            #expect(target.senders.count == 1 && target.senders.first === button)
        }
    }

    @Test func `button presses stay in their own window when labels match`() async throws {
        var actions = [0, 0]
        let views = (0 ..< 2).map { index in
            AnyView(Button("Same title") { actions[index] += 1 }.buttonStyle(.bordered))
        }
        try await TypefluxNavigationTestSupport.withWindows(views) { windows in
            for (index, hosted) in windows.enumerated() {
                try await SettingsBehaviorTestSupport.wait("Same-title button in window \(index)") {
                    SettingsBehaviorTestSupport.contains("Same title", in: hosted.host)
                }
                let element = try SettingsBehaviorTestSupport.button("Same title", in: hosted.host)
                try element.press()
                // SwiftUI may expose only an AX action. Assert both the chosen window and its peer's effect.
                #expect(actions == (index == 0 ? [1, 0] : [1, 1]))
            }
        }
        // A subsequent fixture must still execute after the AX presses and both window teardowns.
        try await TypefluxNavigationTestSupport.withWindow(Button("Following action") { actions[1] += 1 }) { _, host in
            try await SettingsBehaviorTestSupport.wait("Following fixture's button") {
                SettingsBehaviorTestSupport.contains("Following action", in: host)
            }
            try SettingsBehaviorTestSupport.button("Following action", in: host).press()
            #expect(actions == [1, 2])
        }
    }

    private func withoutClickEventLoops(_ press: () throws -> Void) throws {
        // Install only around synchronous dispatch under exclusive UI state; always restore both IMPs.
        let eventSelector = #selector(NSApplication.nextEvent(matching:until:inMode:dequeue:))
        let clickSelector = #selector(NSButtonCell.performClick(_:))
        let eventMethod = try #require(class_getInstanceMethod(NSApplication.self, eventSelector))
        let eventProbe = try #require(class_getInstanceMethod(EventLoopProbe.self, eventSelector))
        let clickMethod = try #require(class_getInstanceMethod(NSButtonCell.self, clickSelector))
        let clickProbe = try #require(class_getInstanceMethod(ButtonCellProbe.self, clickSelector))
        EventLoopProbe.calls = 0
        ButtonCellProbe.calls = 0
        let originalEvent = method_setImplementation(eventMethod, method_getImplementation(eventProbe))
        let originalClick = method_setImplementation(clickMethod, method_getImplementation(clickProbe))
        defer {
            method_setImplementation(clickMethod, originalClick)
            method_setImplementation(eventMethod, originalEvent)
        }
        try press()
        #expect(ButtonCellProbe.calls == 0, "Press must not forward to NSButtonCell.performClick")
        #expect(EventLoopProbe.calls == 0, "Press must not poll AppKit's nested event loop")
    }

    @Test func `switch state changes before its target receives each action`() throws {
        let target = Target()
        let control = NSSwitch(frame: .zero)
        control.target = target
        control.action = #selector(Target.receive(_:))
        control.state = .off
        try SettingsBehaviorTestSupport.Element(object: control).press()
        try SettingsBehaviorTestSupport.Element(object: control).press()
        #expect(target.states == [.on, .off])
        #expect(target.senders.allSatisfy { $0 === control })
    }

    @Test func `rendered button cells dispatch through their owning control`() async throws {
        let target = Target()
        let button = NSButton(title: "Cell", target: target, action: #selector(Target.receive(_:)))
        try await TypefluxNavigationTestSupport.withWindow(NativeButton(button: button)) { window, _ in
            button.displayIfNeeded()
            let cell = try #require(button.cell as? NSButtonCell)
            try SettingsBehaviorTestSupport.Element(object: cell, window: window).press()
            #expect(target.senders.count == 1 && target.senders.first === button)
        }
    }

    @Test func `radio matrix cells select before dispatching the owning control action`() async throws {
        let target = Target()
        let matrix = NSMatrix(frame: NSRect(x: 0, y: 0, width: 200, height: 60), mode: .radioModeMatrix,
                              cellClass: NSButtonCell.self, numberOfRows: 2, numberOfColumns: 1)
        matrix.target = target
        matrix.action = #selector(Target.receive(_:))
        matrix.selectCell(atRow: 0, column: 0)
        try await TypefluxNavigationTestSupport.withWindow(NativeMatrix(matrix: matrix)) { window, _ in
            matrix.displayIfNeeded()
            let cell = try #require(matrix.cell(atRow: 1, column: 0) as? NSButtonCell)
            try SettingsBehaviorTestSupport.Element(object: cell, window: window).press()
            #expect(target.selectedRows == [1])
            #expect(target.senders.count == 1 && target.senders.first === matrix)
        }
    }
}
