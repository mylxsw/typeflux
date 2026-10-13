import AppKit
import SwiftUI
import Testing

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct SettingsBehaviorTestSupportTests {
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
