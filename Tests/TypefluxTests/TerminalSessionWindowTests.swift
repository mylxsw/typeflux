import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite("Session window", .exclusiveUIState)
struct TerminalSessionWindowTests {
    private func shortcut(_ key: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: key,
                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
    }

    @Test func tabsAndRoundTrip() throws {
        let center = TerminalSessionCenter(makeProcess: { FakeTerminalProcess() })
        defer { center.terminateAll() }
        let session = try center.create()
        let terminal = session.terminalView
        let controller = TerminalSessionWindowController()
        var returned: TerminalSession?
        controller.present(session, center: center, settings: .init(), content: { _ in AnyView(EmptyView()) },
                           returnToLauncher: { returned = $0 })
        #expect(session.host == .window(controller.windowID))
        #expect(controller.tabs.count == 1)
        let add = try shortcut("t")
        #expect(controller.handleKey(add))
        let second = try #require(controller.selected)
        #expect(second !== session && center.sessions.count == 2)
        controller.select(8)
        #expect(controller.selected === second)
        controller.togglePin()
        #expect(controller.panel.level == (controller.pinned ? .floating : .normal))
        let first = try shortcut("1")
        #expect(controller.handleKey(first))
        controller.moveBack()
        #expect(returned === session && returned?.terminalView === terminal)
        #expect(session.host == .launcher && controller.selected === second)
        controller.closeTab()
        #expect(controller.tabs.isEmpty && center.sessions.count == 1)
        #expect(!controller.panel.isVisible)
    }

    @Test func liveProgramKeepsTerminalAndRequestsConfirmation() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let secondProcess = FakeTerminalProcess()
        var processes = [process, secondProcess]
        let center = TerminalSessionCenter(history: history, makeProcess: { processes.removeFirst() })
        defer { center.terminateAll() }
        let session = try center.create()
        let controller = TerminalSessionWindowController()
        controller.present(session, center: center, settings: .init(), content: { _ in AnyView(EmptyView()) },
                           returnToLauncher: { _ in })
        controller.addTab()
        secondProcess.emit("\u{1b}]7;file://localhost/tmp/scratch\u{7}")
        controller.select(0)
        process.emit("\u{1b}]7;file://localhost/tmp/typeflux\u{7}")
        #expect(session.submit("top"))
        process.emit("\u{1b}]133;B\u{7}\u{1b}]133;C\u{7}\u{1b}[?1049h")
        #expect(session.alternateScreen)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_SESSION_WINDOW_CAPTURE"] {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            process.emit("\u{1b}[2J\u{1b}[HProcesses: 124 total, 3 running, 121 sleeping\r\n\r\n  PID  COMMAND       CPU       TIME\r\n  412  zsh           0.0   00:01.12\r\n  570  top           1.2   00:02.45")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            let view = try #require(controller.panel.contentView?.superview)
            for (appearance, filename) in [(NSAppearance.Name.darkAqua, "session-window.png"), (.aqua, "session-window-light.png")] {
                controller.panel.appearance = NSAppearance(named: appearance)
                view.displayIfNeeded()
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(filename)
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        let close = try shortcut("w")
        #expect(controller.handleKey(close))
        let sheet = try #require(controller.panel.attachedSheet)
        controller.panel.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        #expect(process.terminations == 0)
        let move = try shortcut("o")
        #expect(controller.handleKey(move))
        #expect(session.host == .launcher && session.alternateScreen)
        #expect(process.started.count == 1 && process.terminations == 0)
        #expect(history.commands == ["top"])
        #expect(!controller.windowShouldClose(controller.panel))
        #expect(controller.tabs.isEmpty && !controller.panel.isVisible)
    }
}
