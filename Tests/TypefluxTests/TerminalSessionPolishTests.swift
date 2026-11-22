// swiftlint:disable file_length
import AppKit
import Darwin
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite(.exclusiveUIState)
struct TerminalSessionPolishTests {
    private let capturePath = ProcessInfo.processInfo.environment["TYPEFLUX_TERMINAL_POLISH_CAPTURES"]

    // Both appearances exercise one live host transition from launch through dismissal.
    @Test(arguments: [true, false])
    // swiftlint:disable:next function_body_length
    func launcherStatusPopoverAndBack(dark: Bool) async throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        _ = NSApplication.shared
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let processes = (0..<4).map { _ in FakeTerminalProcess() }
        var queue = ArraySlice(processes)
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { queue.removeFirst() },
                                           readGitStatus: { _ in nil })
        let apps = ["Calendar", "Notes", "System Settings", "Activity Monitor"].map {
            AskAppEntry(name: $0, url: URL(fileURLWithPath: "/System/Applications/\($0).app"),
                        bundleID: "fixture.\($0)", names: [])
        }
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "", apps: AskTestAppIndex(apps), prepare: { $0.terminalSessionCenter = center }
        )
        let model = launcher.fixture.model
        let window = launcher.window
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = appearance
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { launcher.close(); center.terminateAll() }
        let statusID = "terminal.sessions.status"
        #expect(element(statusID, in: window) == nil)

        let running = try center.create()
        #expect(running.submit("swift build"))
        processes[0].emit(osc("7;file://localhost/tmp/projects/typeflux") + osc("133;B") + osc("133;C") + "Building…\r\n")
        try await wait { element(statusID, in: window) != nil }
        try render(window, as: "01-home", dark: dark)
        try key(38, characters: "j", modifiers: .command, in: window)
        try await wait { popover(for: running, relativeTo: window) != nil }
        let shortcutPopover = try #require(popover(for: running, relativeTo: window))
        try key(38, characters: "j", modifiers: .command, in: shortcutPopover.isKeyWindow ? shortcutPopover : window)
        try await wait { popover(for: running, relativeTo: window) == nil }
        try #require(element(statusID, in: window)).press()
        try await wait { self.popover(for: running, relativeTo: window) != nil }
        let single = try #require(self.popover(for: running, relativeTo: window))
        try key(36, characters: "\r", in: single.isKeyWindow ? single : window)
        try await wait { model.launcherTerminal?.session === running }
        let presentation = try #require(model.launcherTerminal)
        try await wait { element("terminal.launcher.back", in: window) != nil }
        try render(window, as: "08-back", dark: dark, windowServer: false)

        // Escape clears an interactive response and then goes back, leaving the command active.
        processes[0].emit("Continue? ")
        try await wait { presentation.prompt == .input }
        presentation.text = "draft answer"
        try key(53, characters: "\u{1b}", in: window)
        #expect(presentation.text.isEmpty && model.launcherTerminal === presentation)
        try key(51, characters: "\u{7f}", in: window)
        #expect(model.launcherTerminal === presentation)
        try key(53, characters: "\u{1b}", in: window)
        try await wait {
            model.launcherTerminal == nil && element(statusID, in: window) != nil
        }
        #expect(running.runningBlock != nil && processes[0].terminations == 0 && launcher.dismissed == 0)

        let idle = try center.create()
        let codes = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Workspace/codes")
        processes[1].emit(osc("7;" + codes.absoluteString))
        let failed = try center.create()
        #expect(failed.submit("git diff --check"))
        processes[2].emit(osc("133;B") + osc("133;C") + osc("133;D;2"))
        let recent = try center.create()
        #expect(recent.submit("npm run dev"))
        processes[3].emit(osc("133;B") + osc("133;C") + "Ready\r\n")
        processes[0].emit("Running\r\n")
        let newestFirst = TerminalSessionStatus.ordered(model.terminalHomeSessions)
        #expect(newestFirst.map(\.id) == [recent.id, running.id, failed.id, idle.id])
        processes[0].emit("Continue? ")
        let priorityFirst = TerminalSessionStatus.ordered(model.terminalHomeSessions)
        #expect(priorityFirst.map(\.id) == [running.id, recent.id, failed.id, idle.id])
        #expect(TerminalSessionStatus.countBadge(4) == 4)
        #expect(TerminalSessionStatus.countBadge(1) == nil)
        #expect(TerminalSessionStatus.countBadge(0) == nil)

        func runningPopover() -> NSWindow? { popover(for: running, relativeTo: window) }
        try await wait { element(statusID, in: window)?.text == "4" }
        try key(38, characters: "j", modifiers: .command, in: window)
        try await wait { runningPopover() != nil }
        let popup = try #require(runningPopover())
        let keyboardWindow = popup.isKeyWindow ? popup : window
        let secondEndID = "terminal.session.end.\(recent.id)"
        try key(125, characters: "", in: keyboardWindow)
        try await wait { element(secondEndID, in: popup) != nil }
        try key(126, characters: "", in: keyboardWindow)
        try await wait { element(secondEndID, in: popup) == nil }
        popup.appearance = appearance
        // WindowServer can return a partially transparent frame during the opening animation.
        if capturePath != nil { try await Task.sleep(for: .milliseconds(350)) }
        try hover(try #require(element("terminal.session.open.\(idle.id)", in: popup)), in: popup)
        let endID = "terminal.session.end.\(idle.id)"
        try await wait { element(endID, in: popup) != nil }
        try render(window, as: "02-home-behind-popover", dark: dark)
        try render(popup, as: "02-popover", dark: dark, frame: true)
        try #require(element(endID, in: popup)).press()
        try await wait { !center.sessions.contains { $0 === idle } }
        #expect(processes[1].terminations == 1)
        try key(38, characters: "j", modifiers: .command, in: popup.isKeyWindow ? popup : window)
        try await wait { runningPopover() == nil }

        model.launcherWindowMode = .simple
        #expect(model.launcherIsCollapsed && !model.launcherNeedsFullWindow)
        window.setContentSize(NSSize(width: window.frame.width, height: AskLauncherWindowMode.simpleHeight))
        try await wait { element(statusID, in: window) != nil }
        try render(window, as: "03-simple", dark: dark, windowServer: false)
        let editor = try #require(window.contentView.flatMap(composerEditor(in:)))
        #expect(window.makeFirstResponder(editor))
        try key(53, characters: "\u{1b}", in: window)
        #expect(launcher.dismissed == 1)
        processes[0].exit(1)
        #expect(!center.sessions.contains { $0 === running } && processes[0].terminations == 0)
    }

    @Test(arguments: [false, true])
    func commandCardsKeepTheirFramesOnHover(running: Bool) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }

        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process }, readGitStatus: { _ in nil })
        defer { center.terminateAll() }
        let session = try center.create()
        let model = TerminalLauncherModel(session: session, settings: .init(), source: nil,
                                          notify: { _, _ in false }, visible: { true })
        process.emit(osc("133;B"))
        try #require(session.submit("pwd"))
        process.emit(osc("133;C") + "/tmp/projects\r\n" + osc("133;D;0") + osc("133;B"))
        try #require(session.submit("echo Ready"))
        process.emit(osc("133;C") + "Ready\r\n")
        if !running { process.emit(osc("133;D;0") + osc("133;B")) }
        try #require(session.blocks.count == 2)

        let ids = session.blocks.map { "terminal.block.\($0.id)" }
        let action = running ? L("terminal.launcher.interrupt") + " ⌃C" : L("terminal.launcher.copy") + " ⌘C"
        let view = TerminalLauncherView(model: model, session: session, sessions: [session],
                                        select: { _ in }, new: {}, close: {}, move: nil, back: {},
                                        insert: { _ in }, commands: { [] }, error: { _ in })
        try await SettingsBehaviorTestSupport.withWindow(view, width: 720, height: 240) { window, _ in
            @MainActor func frames() -> [NSRect] { ids.compactMap { element($0, in: window)?.frame } }
            @MainActor func actionIsVisible() -> Bool {
                SettingsBehaviorTestSupport.elements(in: window).contains { $0.label == action }
            }
            try await wait { frames().count == 2 && frames().allSatisfy { !$0.isEmpty } }
            let resting = frames()
            #expect(!actionIsVisible())
            let card = try #require(element(ids[running ? 1 : 0], in: window))
            try hover(card, in: window)
            try await wait { actionIsVisible() }
            #expect(frames() == resting)
            try hover(card, in: window, inside: false)
            try await wait { !actionIsVisible() }
            #expect(frames() == resting)
        }
    }

    @Test func sessionStatusTitleUsesFolderUntilACommandExists() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process }, readGitStatus: { _ in nil })
        defer { center.terminateAll() }
        let session = try center.create()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        process.emit(osc("7;" + home.absoluteString))
        #expect(session.statusRowTitle == "~")
        #expect(session.displayDirectory(session.cwd) == "~")

        let codes = home.appendingPathComponent("Workspace/codes")
        process.emit(osc("7;" + codes.absoluteString))
        #expect(session.statusRowTitle == "codes")
        #expect(session.displayDirectory(session.cwd) == "~/Workspace/codes")

        #expect(session.submit("pwd"))
        #expect(session.statusRowTitle == "pwd")
    }

    @Test func backgroundWindowCanBeOpenedAndEndedFromTheLauncher() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let fixture = try AskTestFixture()
        let window = TerminalSessionWindowController()
        let model = fixture.model
        model.terminalSessionCenter = center
        model.terminalSessionWindow = window
        defer {
            for session in window.tabs { window.endTab(session) }
            center.terminateAll()
            model.resetSession()
        }
        model.launchTerminal(settings: .init(), window: true)
        let session = try #require(window.selected)
        window.panel.orderOut(nil)
        var dismissed = false
        model.openTerminalHomeSession(session.id) { dismissed = true }
        #expect(dismissed && window.panel.isVisible && window.selected === session)
        model.endTerminalHomeSession(session.id)
        model.endTerminalHomeSession(session.id)
        #expect(window.tabs.isEmpty && center.sessions.isEmpty)
        #expect(!window.panel.isVisible && process.terminations == 1)
    }

    // The sheet sequence shares the same sessions and tab selection throughout.
    @Test(arguments: [true, false])
    // swiftlint:disable:next function_body_length
    func windowTabsReorderAndCloseInOrder(dark: Bool) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let firstProcess = FakeTerminalProcess(), secondProcess = FakeTerminalProcess()
        let failedProcess = FakeTerminalProcess(), exitedProcess = FakeTerminalProcess()
        var queue = ArraySlice([firstProcess, secondProcess, failedProcess, exitedProcess])
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { queue.removeFirst() },
                                           readGitStatus: { _ in nil })
        let fixture = try AskTestFixture()
        let controller = TerminalSessionWindowController()
        let model = fixture.model
        model.terminalSessionCenter = center
        model.terminalSessionWindow = controller
        defer {
            if let sheet = controller.panel.attachedSheet { controller.panel.endSheet(sheet, returnCode: .cancel) }
            for session in controller.tabs { controller.endTab(session) }
            center.terminateAll()
            model.resetSession()
        }
        controller.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        model.launchTerminal(command: "swift build", settings: .init(), window: true)
        let first = try #require(controller.selected)
        firstProcess.emit(osc("7;file://localhost/tmp/projects/typeflux")
                          + osc("133;B") + osc("133;C") + "Building Typeflux…\r\n")
        model.launchTerminal(command: "read response", settings: .init(), window: true)
        let second = try #require(controller.selected)
        secondProcess.emit(osc("7;file://localhost/tmp/other/typeflux") + osc("133;B") + osc("133;C") + "Continue? ")
        model.launchTerminal(command: "git diff --check", settings: .init(), window: true)
        let failed = try #require(controller.selected)
        failedProcess.emit(osc("7;file://localhost/tmp/projects/typeflux")
                           + osc("133;B") + osc("133;C") + osc("133;D;2"))
        model.launchTerminal(settings: .init(), window: true)
        let exited = try #require(controller.selected)
        exitedProcess.exit(0)

        #expect(first.tabFolder == "typeflux" && first.tabCommand(duplicateFolder: false) == "swift build")
        #expect(first.tabTooltip == "/tmp/projects/typeflux\nswift build")
        #expect(failed.tabCommand(duplicateFolder: false) == nil)
        #expect(failed.tabCommand(duplicateFolder: true) == "git diff --check")
        #expect(exited.tabTooltip == exited.cwd)
        #expect(controller.reorder(failed.id, to: first.id))
        #expect(controller.tabs.map(\.id) == [failed.id, first.id, second.id])
        #expect(controller.selected === failed && !controller.reorder(first.id, to: first.id))
        #expect(controller.reorder(failed.id, to: second.id))
        #expect(controller.tabs.map(\.id) == [first.id, second.id, failed.id])
        #expect(!center.sessions.contains { $0 === exited } && exitedProcess.terminations == 0)
        #expect(!controller.reorder(UUID(), to: first.id))

        func shortcut(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: controller.panel.windowNumber, context: nil, characters: "w",
                                         charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        }

        let close = try shortcut(.command)
        controller.select(0)
        let tabID = "terminal.tab.\(first.id)"
        try await wait { element(tabID, in: controller.panel) != nil }
        try hover(try #require(element(tabID, in: controller.panel)), in: controller.panel)
        let closeID = "terminal.tab.close.\(first.id)"
        try await wait { element(closeID, in: controller.panel) != nil }
        try render(controller.panel, as: "05-tabs", dark: dark, frame: true)
        try #require(element(closeID, in: controller.panel)).press()
        try await wait { controller.panel.attachedSheet != nil }
        let firstSheet = try #require(controller.panel.attachedSheet)
        firstSheet.appearance = controller.panel.appearance
        try await Task.sleep(for: .milliseconds(200))
        try render(controller.panel, as: "06-tabs-behind-confirm", dark: dark, frame: true)
        try render(firstSheet, as: "06-confirm", dark: dark, frame: true)
        controller.panel.endSheet(firstSheet, returnCode: .alertSecondButtonReturn)
        try await wait { controller.panel.attachedSheet == nil }
        #expect(firstProcess.terminations == 0 && controller.tabs.count == 3)

        // Keep the failed tab; decline the first running tab and confirm the second.
        controller.select(2)
        let closeOthers = try shortcut([.command, .option])
        #expect(controller.handleKey(closeOthers))
        let anotherSheet = try #require(controller.panel.attachedSheet)
        controller.panel.endSheet(anotherSheet, returnCode: .alertSecondButtonReturn)
        try await wait {
            controller.panel.attachedSheet.map { $0 !== anotherSheet } ?? false
        }
        let waitingSheet = try #require(controller.panel.attachedSheet)
        controller.panel.endSheet(waitingSheet, returnCode: .alertFirstButtonReturn)
        try await wait { controller.tabs.count == 2 }
        #expect(controller.tabs.map(\.id) == [first.id, failed.id] && secondProcess.terminations == 1)
        #expect(controller.handleKey(close))
        #expect(controller.panel.attachedSheet == nil && failedProcess.terminations == 1)
        #expect(controller.handleKey(close))
        let lastSheet = try #require(controller.panel.attachedSheet)
        controller.panel.endSheet(lastSheet, returnCode: .alertFirstButtonReturn)
        try await wait { controller.tabs.isEmpty }
        #expect(!controller.panel.isVisible && center.sessions.isEmpty && firstProcess.terminations == 1)
    }
}

extension TerminalSessionPolishTests {
    @Test(arguments: [true, false])
    // swiftlint:disable:next function_body_length
    func launcherEndsSessionsFromListAndHeader(dark: Bool) async throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        _ = NSApplication.shared
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let processes = (0..<4).map { _ in FakeTerminalProcess() }
        var queue = ArraySlice(processes)
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { queue.removeFirst() },
                                           readGitStatus: { _ in nil })
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "", apps: AskTestAppIndex([]), prepare: { $0.terminalSessionCenter = center }
        )
        let model = launcher.fixture.model
        let window = launcher.window
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }
        window.appearance = appearance
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { launcher.close(); center.terminateAll() }
        let statusID = "terminal.sessions.status"
        let endID = "terminal.launcher.end"

        let idle = try center.create()
        try await wait { element(statusID, in: window) != nil }
        try #require(element(statusID, in: window)).press()
        try await wait { popover(for: idle, relativeTo: window) != nil }
        let popup = try #require(popover(for: idle, relativeTo: window))
        #expect(model.launcherTerminal == nil)
        popup.appearance = appearance
        if capturePath != nil { try await Task.sleep(for: .milliseconds(350)) }
        try render(window, as: "09-home", dark: dark, windowServer: false)
        try render(popup, as: "09-single-session", dark: dark, frame: true)
        try #require(element("terminal.session.end.\(idle.id)", in: popup)).press()
        try await wait { element(statusID, in: window) == nil && !popup.isVisible }
        #expect(center.sessions.isEmpty && processes[0].terminations == 1)

        model.launchTerminal(settings: .init())
        try await wait { element(endID, in: window) != nil }
        try await waitForTerminalKeys(in: window)
        try key(13, characters: "w", modifiers: .command, in: window)
        try await wait { model.launcherTerminal == nil && element(endID, in: window) == nil }
        #expect(center.sessions.isEmpty && processes[1].terminations == 1)

        let failed = try center.create()
        #expect(failed.submit("false"))
        processes[2].emit(osc("133;B") + osc("133;C") + osc("133;D;1"))
        model.resumeLauncherTerminal(failed.id)
        try await wait { element(endID, in: window) != nil }
        try #require(element(endID, in: window)).press()
        try await wait { model.launcherTerminal == nil && element(endID, in: window) == nil }
        #expect(center.sessions.isEmpty && processes[2].terminations == 1)

        model.launchTerminal(command: "swift build", settings: .init())
        let running = try #require(model.launcherTerminal?.session)
        processes[3].emit(osc("7;file://localhost/tmp/projects/typeflux")
                          + osc("133;B") + osc("133;C") + "Building Typeflux…\r\n")
        try await wait { element(endID, in: window) != nil }
        try render(window, as: "10-terminal", dark: dark, windowServer: false)
        try await waitForTerminalKeys(in: window)
        try await respondToCloseAlert(with: .alertSecondButtonReturn, dark: dark, capture: true) {
            try key(13, characters: "w", modifiers: .command, in: window)
        }
        #expect(model.launcherTerminal?.session === running && processes[3].terminations == 0)
        processes[3].emit("\u{1b}[?1049h")
        try await wait { running.alternateScreen && element("terminal.blockList", in: window) == nil }
        try await waitForTerminalKeys(in: window, listeners: 1)
        try await respondToCloseAlert(with: .alertSecondButtonReturn, dark: dark) {
            try key(13, characters: "w", modifiers: .command, in: window)
        }
        #expect(model.launcherTerminal?.session === running && processes[3].terminations == 0)
        processes[3].emit("\u{1b}[?1049l")
        try await wait { element("terminal.blockList", in: window) != nil }
        try await respondToCloseAlert(with: .alertFirstButtonReturn, dark: dark) {
            try #require(element(endID, in: window)).press()
        }
        #expect(model.launcherTerminal == nil && center.sessions.isEmpty && processes[3].terminations == 1)
        try await wait { element(statusID, in: window) == nil }
    }

    @Test func sessionStatusSubtitleAppearsOnlyWhenItDiffersFromTheTitle() throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { process }, readGitStatus: { _ in nil })
        defer { center.terminateAll() }
        let session = try center.create()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        process.emit(osc("7;" + home.absoluteString))
        #expect(session.statusRowTitle == "~")
        #expect(session.statusRowSubtitle == nil)

        let codes = home.appendingPathComponent("Workspace/codes")
        process.emit(osc("7;" + codes.absoluteString))
        #expect(session.statusRowSubtitle == "~/Workspace/codes")

        #expect(session.submit("~/Workspace/codes"))
        #expect(session.statusRowSubtitle == nil)
    }

    @Test func shellExitReturnsToLauncherHome() async throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        _ = NSApplication.shared
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let exit = FakeTerminalProcess()
        let eof = FakeTerminalProcess()
        var processes = [exit, eof]
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = TerminalSessionCenter(history: history, makeProcess: { processes.removeFirst() },
                                           readGitStatus: { _ in nil })
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "", apps: AskTestAppIndex([]), prepare: { $0.terminalSessionCenter = center }
        )
        let model = launcher.fixture.model
        defer { launcher.close(); center.terminateAll() }

        model.launchTerminal(settings: .init())
        let terminal = try #require(model.launcherTerminal)
        exit.emit(osc("133;A") + osc("133;B"))
        terminal.fill("exit")
        #expect(terminal.submit())
        #expect(exit.writes.last == Array("\u{1b}[200~exit\u{1b}[201~\r".utf8))
        exit.exit(0)
        #expect(center.sessions.isEmpty && model.launcherTerminal == nil && model.terminalPresentations.isEmpty)
        #expect(exit.terminations == 0)
        let endID = "terminal.launcher.end"
        try await wait { element(endID, in: launcher.window) == nil }
        model.launchTerminal(settings: .init())
        try await wait { element(endID, in: launcher.window) != nil }
        try await waitForTerminalKeys(in: launcher.window)
        try key(2, characters: "d", modifiers: .control, in: launcher.window)
        #expect(eof.writes.last == [4])
        eof.exit(0)
        #expect(center.sessions.isEmpty && model.launcherTerminal == nil && eof.terminations == 0)
    }

}

extension TerminalSessionPolishTests {
    private func render(_ window: NSWindow, as name: String, dark: Bool, frame: Bool = false,
                        windowServer: Bool = true) throws {
        guard let capturePath else { return }
        let directory = URL(fileURLWithPath: capturePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        if windowServer, let snapshot = ownedWindowSnapshot(window),
           snapshot.pixelsWide >= Int(window.frame.width / 2),
           snapshot.pixelsHigh >= Int(window.frame.height / 2),
           let png = snapshot.representation(using: .png, properties: [:]) {
            try png.write(to: url)
            return
        }
        let view = try #require(frame ? window.contentView?.superview : window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    // Capture the WindowServer backdrop for this test's own window. The legacy
    // entry point remains available on systems where Swift marks it unavailable.
    private func ownedWindowSnapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let id = CGWindowID(exactly: window.windowNumber),
              NSApp.windows.contains(where: { $0 === window }),
              let process = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(process) }
        guard let symbol = dlsym(process, "CGWindowListCreateImage") else { return nil }
        typealias Capture = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                            CGWindowImageOption.boundsIgnoreFraming.rawValue)
        return image.map { NSBitmapImageRep(cgImage: $0.takeRetainedValue()) }
    }

    private func composerEditor(in view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(composerEditor(in:)).first
    }

    private func popover(for session: TerminalSession, relativeTo window: NSWindow) -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0 !== window && element("terminal.session.open.\(session.id)", in: $0) != nil
        }
    }

    private func waitForTerminalKeys(in window: NSWindow, listeners: Int = 2) async throws {
        func attachedListeners(in view: NSView) -> Int {
            let listener = view as? TerminalKeyCapture.Listener
            let ready = listener?.handler != nil && listener?.window === window
            return view.subviews.reduce(ready ? 1 : 0) { $0 + attachedListeners(in: $1) }
        }

        window.makeKeyAndOrderFront(nil)
        try await wait {
            guard let content = window.contentView else { return false }
            return attachedListeners(in: content) == listeners
        }
    }

    private func respondToCloseAlert(with response: NSApplication.ModalResponse, dark: Bool,
                                     capture: Bool = false, action: () throws -> Void) async throws {
        var handled = false
        var captureError: Error?
        let deadline = ContinuousClock.now + .seconds(3)
        let captureScreenshot = capture && capturePath != nil
        var screenshotReadyAt: ContinuousClock.Instant?
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else {
                    if ContinuousClock.now >= deadline { timer.invalidate() }
                    return
                }
                if captureScreenshot {
                    // Let the alert finish animating before capturing its window.
                    let readyAt = screenshotReadyAt ?? (ContinuousClock.now + .milliseconds(650))
                    screenshotReadyAt = readyAt
                    guard ContinuousClock.now >= readyAt else { return }
                }
                timer.invalidate()
                handled = true
                modal.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if capture {
                    modal.displayIfNeeded()
                    do {
                        try render(modal, as: "10-confirm", dark: dark, frame: true, windowServer: dark)
                    } catch {
                        captureError = error
                    }
                }
                #expect(SettingsBehaviorTestSupport.contains(L("terminal.session.end.message"), in: modal))
                #expect(SettingsBehaviorTestSupport.contains(L("terminal.session.end"), in: modal))
                #expect(SettingsBehaviorTestSupport.contains(L("common.cancel"), in: modal))
                NSApp.stopModal(withCode: response)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        try action()
        try await wait { handled }
        if let captureError { throw captureError }
    }

    private func element(_ id: String, in window: NSWindow) -> SettingsBehaviorTestSupport.Element? {
        SettingsBehaviorTestSupport.elements(in: window).first { $0.value("accessibilityIdentifier") as? String == id }
    }

    private func wait(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func hover(_ control: SettingsBehaviorTestSupport.Element, in window: NSWindow,
                       inside: Bool = true) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: control.frame.midX, y: control.frame.midY))
        func dispatch(in view: NSView) {
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(point, from: nil)), let owner = area.owner as? NSResponder else {
                    continue
                }
                let event = TerminalPolishHoverEvent(area: area, point: point, window: window, inside: inside)
                if inside { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
            }
            view.subviews.forEach(dispatch)
        }
        dispatch(in: try #require(window.contentView))
    }

    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }

    private func osc(_ value: String) -> String { "\u{1b}]" + value + "\u{7}" }
}

private final class TerminalPolishHoverEvent: NSEvent {
    private let area: NSTrackingArea
    private let point: NSPoint
    private let targetWindowNumber: Int
    private let eventType: NSEvent.EventType

    init(area: NSTrackingArea, point: NSPoint, window: NSWindow, inside: Bool) {
        self.area = area
        self.point = point
        targetWindowNumber = window.windowNumber
        eventType = inside ? .mouseEntered : .mouseExited
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { targetWindowNumber }
    override var type: NSEvent.EventType { eventType }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
