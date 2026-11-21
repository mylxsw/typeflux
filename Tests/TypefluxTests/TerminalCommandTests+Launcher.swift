import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension TerminalCommandTests {
    @Test func `outside dismissal waits for consent but explicit cancellation stays available`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        dispatcher.pauseAuthorization = true
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        #expect(model.allowsLauncherOutsideDismissal)
        model.submitTerminalCommand(request) { Issue.record("Cancelled command completed") }
        #expect(!model.allowsLauncherOutsideDismissal)
        try await AskQuickSearchSessionTests.wait { dispatcher.authorization != nil }
        model.foldLauncherKeyword()
        #expect(model.allowsLauncherOutsideDismissal)
        dispatcher.authorization?.resume(); dispatcher.authorization = nil
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(dispatcher.requests.isEmpty)
        model.recordingIsActive = { true }
        #expect(!model.allowsLauncherOutsideDismissal)
        model.recordingIsActive = { false }
    }

    @Test func `cancelling before the dispatch task starts never requests permission`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        model.submitTerminalCommand(request) { Issue.record("Cancelled command completed") }
        model.foldLauncherKeyword()
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(dispatcher.authorizations.isEmpty && dispatcher.requests.isEmpty)
    }

    @Test func riskyInitialSubmissionRequiresExplicitConfirmationAndRejectsStaleInput() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model, command: "git push --force")
        var completed = 0
        model.submitTerminalCommand(request) { completed += 1 }
        #expect(model.pendingTerminalRisk?.risk == .forcePush && dispatcher.authorizations.isEmpty)
        #expect(model.cancelTerminalRisk() && !model.cancelTerminalRisk())
        model.confirmTerminalRisk { completed += 1 }
        #expect(dispatcher.requests.isEmpty && completed == 0)
        model.submitTerminalCommand(request) { completed += 1 }
        model.launcherDraft.text = "git status"
        model.confirmTerminalRisk { completed += 1 }
        #expect(dispatcher.authorizations.isEmpty && completed == 0)
        model.launcherDraft.text = request.command
        model.submitTerminalCommand(request) { completed += 1 }
        model.confirmTerminalRisk { completed += 1 }
        model.confirmTerminalRisk { completed += 1 }
        try await AskQuickSearchSessionTests.wait { completed == 1 }
        #expect(dispatcher.requests == [request] && model.pendingTerminalRisk == nil)
    }

    @Test func riskyHintUsesEscapeAndCommandReturn() async throws {
        let dispatcher = TestTerminalDispatcher()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "cmd git push --force", prepare: {
            $0.terminalCommandDispatcher = dispatcher
        })
        defer { launcher.close() }
        let model = launcher.fixture.model
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        try await launcher.press(36, .option)
        try await AskQuickSearchSessionTests.wait { model.pendingTerminalRisk != nil }
        #expect(dispatcher.requests.isEmpty)
        try await launcher.press(53)
        #expect(model.pendingTerminalRisk == nil && launcher.dismissed == 0)
        try await launcher.press(36, .option)
        try await launcher.press(36, .command)
        try await AskQuickSearchSessionTests.wait { dispatcher.requests.count == 1 }
        #expect(dispatcher.requests.first?.runner == .external)
    }

    @Test func `dispatch uses the snapshot and prevents duplicates`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        dispatcher.pauseSend = true
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model, command: "  printf '%s' \"a b\"  ", terminal: .iterm)
        var completed = 0
        model.submitTerminalCommand(request) { completed += 1 }
        model.submitTerminalCommand(request) { completed += 1 }
        try await AskQuickSearchSessionTests.wait { dispatcher.sending != nil }
        #expect(dispatcher.authorizations == [.iterm] && dispatcher.requests == [request])
        dispatcher.sending?.resume(); dispatcher.sending = nil
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(completed == 1 && !model.plugins.isActive)
        #expect(model.launcherInputHistory.history.entries.isEmpty)
    }

    @Test func `stale or forged actions and programmatic actions do not dispatch`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        #expect(model.performPluginAction(.init(kind: .terminalCommand(request), title: "", symbol: "")) == .stay)
        model.submitTerminalCommand(.init(command: "different", terminal: .terminal)) {}
        model.submitTerminalCommand(.init(command: "pwd", terminal: .iterm)) {}
        model.launcherDraft.text = "changed"
        model.submitTerminalCommand(request) {}
        #expect(dispatcher.authorizations.isEmpty && dispatcher.requests.isEmpty)
    }

    @Test(arguments: [true, false]) func `consent cannot execute stale input`(changePresentation: Bool) async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        dispatcher.pauseAuthorization = true
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        model.submitTerminalCommand(request) { Issue.record("Stale dispatch completed") }
        try await AskQuickSearchSessionTests.wait { dispatcher.authorization != nil }
        if changePresentation {
            model.launcherPresentationID = UUID()
        } else {
            model.launcherDraft.text = "changed"
        }
        dispatcher.authorization?.resume(); dispatcher.authorization = nil
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(dispatcher.requests.isEmpty)
    }

    @Test func `permission failure keeps input and does not replay`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        dispatcher.authorizationError = .permissionDenied
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        model.submitTerminalCommand(request) { Issue.record("Denied dispatch completed") }
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(dispatcher.requests.isEmpty && model.launcherDraft.text == "pwd")
        #expect(model.commandFeedback == TerminalCommandError.permissionDenied.localizedDescription)
        #expect(model.plugins.plan?.action(for: .optionEnter)?.kind == .terminalCommand(request))
    }

    @Test func `disabled keyword during consent does not dispatch`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        dispatcher.pauseAuthorization = true
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        model.submitTerminalCommand(request) { Issue.record("Disabled keyword completed") }
        try await AskQuickSearchSessionTests.wait { dispatcher.authorization != nil }
        var keyword = AskTerminalCommandPlugin.keywords[0]
        keyword.enabled = false
        model.modelLibrary.settings.saveAskLauncherKeywords([keyword])
        dispatcher.authorization?.resume(); dispatcher.authorization = nil
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(dispatcher.requests.isEmpty)
    }

    @Test func `cancelled consent failure does not present an obsolete alert`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        dispatcher.pauseAuthorization = true
        dispatcher.authorizationError = .permissionDenied
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        model.submitTerminalCommand(request) { Issue.record("Cancelled consent completed") }
        try await AskQuickSearchSessionTests.wait { dispatcher.authorization != nil }
        model.foldLauncherKeyword()
        dispatcher.authorization?.resume(); dispatcher.authorization = nil
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(dispatcher.requests.isEmpty && model.launcherDraft.text.isEmpty)
    }

    @Test func `uncertain receipt does not replay or report completion`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        dispatcher.sendError = .uncertain
        model.terminalCommandDispatcher = dispatcher
        let request = try await prepare(model)
        model.submitTerminalCommand(request) { Issue.record("Uncertain dispatch completed") }
        try await AskQuickSearchSessionTests.wait { !model.terminalCommandSending }
        #expect(dispatcher.requests == [request] && model.launcherDraft.text == "pwd")
        #expect(model.commandFeedback == TerminalCommandError.uncertain.localizedDescription)
    }

    @Test func `command never becomes history or an AI request`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        _ = try await prepare(model, command: "echo private")
        model.recordLauncherInput(destination: .keyword)
        model.recordAbandonedLauncherInput()
        model.askAIFromPlugin()
        model.submitLauncher()
        #expect(model.launcherInputHistory.history.entries.isEmpty)
        #expect(await fixture.api.sends.isEmpty)
        model.foldLauncherKeyword()
        #expect(model.launcherDraft.text.isEmpty)
        for text in ["cmd echo private", "> echo private"] {
            model.launcherDraft.text = text
            model.recordAbandonedLauncherInput()
            model.submitLauncher()
            #expect(model.launcherInputHistory.history.entries.isEmpty)
            #expect(await fixture.api.sends.isEmpty)
            model.launcherDismissedAt = Date()
            _ = model.resetLauncherForPresentation()
            #expect(model.launcherDraft.text.isEmpty)
        }
    }

    @Test func `workflow and keyword hotkey only prepare the mode`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        model.terminalCommandDispatcher = dispatcher
        #expect(model.runLauncherKeyword("cmd", argument: "pwd", chain: ["workflow"]))
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        #expect(dispatcher.requests.isEmpty && !model.plugins.isRunning)
        model.enterKeywordShortcut(.init(binding: .defaultAuxiliary, keyword: "cmd",
                                         pluginID: AskTerminalCommandPlugin.id), refreshingWorkflows: false)
        #expect(model.isTerminalCommandMode && model.launcherDraft.text.isEmpty)
        #expect(dispatcher.requests.isEmpty)
    }

    @Test(arguments: [
        "cmd",
        ">"
    ]) func `actual launcher requires return and esc clears input`(word: String) async throws {
        let dispatcher = TestTerminalDispatcher()
        let process = FakeTerminalProcess()
        let center = TerminalSessionCenter(
            history: TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeProcess: { process }
        )
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: word + " pwd", prepare: {
            $0.terminalCommandDispatcher = dispatcher
            $0.terminalSessionCenter = center
        })
        defer { launcher.close(); center.terminateAll() }
        let model = launcher.fixture.model
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        #expect(model.isTerminalCommandMode && launcher.editor.font?.isFixedPitch == true)
        #expect(dispatcher.requests.isEmpty && center.sessions.isEmpty)
        try await launcher.press(15, .command)
        #expect(dispatcher.requests.isEmpty && center.sessions.isEmpty)
        #expect(await launcher.fixture.api.sends.isEmpty)
        try await launcher.press(53)
        #expect(model.launcherDraft.text.isEmpty && !model.plugins.isActive)
        #expect(model.launcherInputHistory.history.entries.isEmpty)
        model.launcherDraft.text = word + " pwd"
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        try await launcher.press(36)
        let terminal = try #require(model.launcherTerminal)
        #expect(terminal.session.runningBlock?.command == "pwd")
        process.emit("\u{1b}]133;B\u{7}")
        #expect(!process.writes.isEmpty)
        #expect(dispatcher.requests.isEmpty && dispatcher.authorizations.isEmpty)
        #expect(launcher.dismissed == 0 && !model.plugins.isActive)
        model.foldLauncherKeyword()
        #expect(model.launcherTerminal == nil && process.terminations == 0)
        #expect(model.terminalHomeRows.first?.action == .terminalSession(terminal.session.id))
        model.resumeLauncherTerminal(terminal.session.id)
        #expect(model.launcherTerminal === terminal)
        #expect(model.launcherInputHistory.history.entries.isEmpty)
    }

    @Test func `moving the launcher terminal keeps its running PTY and output`() throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        let process = FakeTerminalProcess()
        let center = TerminalSessionCenter(
            history: TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeProcess: { process }
        )
        model.terminalSessionCenter = center
        let window = TerminalSessionWindowController()
        model.terminalSessionWindow = window
        defer {
            window.moveBack()
            center.terminateAll()
            model.resetSession()
        }
        model.launchTerminal(command: "printf output", settings: .init())
        let session = try #require(model.launcherTerminal?.session)
        process.emit("\u{1b}]133;B\u{7}\u{1b}]133;C\u{7}output")
        let block = session.runningBlock?.id
        var dismissed = false
        model.moveLauncherTerminal { dismissed = true }
        #expect(dismissed && model.launcherTerminal == nil && model.terminalHomeRows.first?.symbol == "macwindow")
        #expect(window.selected === session && session.host == .window(window.windowID))
        #expect(center.sessions.first === session)
        #expect(session.runningBlock?.id == block && process.started.count == 1 && process.terminations == 0)
        process.emit("\r\n\u{1b}]133;D;0\u{7}")
        #expect(session.blocks.last?.output.string == "output")
        window.moveBack()
        #expect(model.launcherTerminal?.session === session && session.host == .launcher)
    }

    @Test func `terminal hint fills a recent command without running it`() async throws {
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        history.record("git status")
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "> gi", prepare: {
            $0.terminalSessionCenter = center
        })
        defer { launcher.close(); center.terminateAll() }
        let model = launcher.fixture.model
        try await AskQuickSearchSessionTests.wait { model.isTerminalCommandMode }
        for _ in 0 ..< 3 { try await launcher.press(125) }
        try await launcher.press(48)
        #expect(model.launcherDraft.text == "git status" && center.sessions.isEmpty)
        try await launcher.press(36)
        #expect(model.launcherTerminal?.session.runningBlock?.command == "git status")
    }

    @Test func `launcher terminal handles block and session shortcuts`() async throws {
        let processes = [FakeTerminalProcess(), FakeTerminalProcess()]
        var nextProcess = 0
        let center = TerminalSessionCenter(
            history: TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeProcess: {
                defer { nextProcess += 1 }
                return processes[nextProcess]
            }
        )
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "> printf first", prepare: {
            $0.terminalSessionCenter = center
            $0.passiveNotice = { _ in }
        })
        let previousPasteboard = AskQuickResults.pasteboard
        let pasteboard = NSPasteboard(name: .init("terminal-keys." + UUID().uuidString))
        AskQuickResults.pasteboard = pasteboard
        defer {
            AskQuickResults.pasteboard = previousPasteboard
            launcher.close()
            center.terminateAll()
        }
        let model = launcher.fixture.model
        try await AskQuickSearchSessionTests.wait { model.isTerminalCommandMode }
        try await launcher.press(36)
        let presentation = try #require(model.launcherTerminal)
        let session = presentation.session
        let process = processes[0]
        func osc(_ text: String) -> String { "\u{1b}]" + text + "\u{7}" }
        process.emit(osc("133;B") + osc("133;C") + "first\r\n")

        try await terminalKey(2, .control, in: launcher.window)
        #expect(process.writes.last == [4])
        try await terminalKey(8, .control, in: launcher.window)
        #expect(process.writes.last == [3])
        process.emit(osc("133;D;130") + osc("133;B"))
        try await terminalKey(126, .option, in: launcher.window)
        #expect(presentation.actionBlock?.state == .interrupted)
        try await terminalKey(8, .command, in: launcher.window)
        #expect(pasteboard.string(forType: .string) == "first")
        try await terminalKey(15, .command, in: launcher.window)
        #expect(session.runningBlock?.command == "printf first")
        try await terminalKey(40, .command, in: launcher.window)
        #expect(session.blocks.count == 1)
        try await terminalKey(17, .command, in: launcher.window)
        let second = try #require(model.launcherTerminal?.session)
        #expect(second !== session && center.sessions.count == 2)
        try await terminalKey(18, .command, characters: "1", in: launcher.window)
        #expect(model.launcherTerminal?.session === session)
        try await terminalKey(19, .command, characters: "2", in: launcher.window)
        #expect(model.launcherTerminal?.session === second)
        try await terminalKey(13, .command, in: launcher.window)
        #expect(model.launcherTerminal?.session === session && center.sessions.count == 1)
        try await terminalKey(53, [], in: launcher.window)
        #expect(launcher.dismissed == 1)
    }

    private func terminalKey(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags,
                             characters: String = "", in window: NSWindow) async throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: code))
        NSApplication.shared.sendEvent(event)
        try await Task.sleep(for: .milliseconds(55))
    }

    @Test(arguments: [true, false]) func `capture launcher terminal states`(dark: Bool) async throws {
        let folder = ProcessInfo.processInfo.environment["TYPEFLUX_TERMINAL_SNAPSHOTS"]
            .map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let process = FakeTerminalProcess()
        let history = TerminalCommandHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        history.record("git status --short")
        history.record("git log -5")
        let project = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/typeflux")
        let center = TerminalSessionCenter(history: history, makeProcess: { process }, readGitStatus: {
            $0 == project.path ? TerminalGitStatus(branch: "main", dirty: true) : nil
        })
        let tabbedWindow = TerminalSessionWindowController()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "> git sta", prepare: {
            $0.terminalSessionCenter = center
            $0.terminalSessionWindow = tabbedWindow
        })
        defer { tabbedWindow.moveBack(); launcher.close(); center.terminateAll() }
        let model = launcher.fixture.model
        let window = launcher.window
        let enhancedAccessibility = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: enhancedAccessibility)
        defer { NSApp.accessibilitySetValue(false, forAttribute: enhancedAccessibility) }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let theme = dark ? "dark" : "light"

        func capture(_ name: String, in panel: NSWindow? = nil) async throws {
            try await Task.sleep(for: .milliseconds(120))
            let host = panel ?? window
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if panel == nil, let height = launcher.heights.last {
                window.setContentSize(NSSize(width: window.frame.width, height: height))
            }
            let view = try #require(panel == nil ? host.contentView : host.contentView?.superview)
            view.layoutSubtreeIfNeeded()
            guard let folder else { return }
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("\(name)-\(theme).png"))
        }
        func osc(_ text: String) -> String { "\u{1b}]" + text + "\u{7}" }
        func accessibilityFrame(_ identifier: String) throws -> NSRect {
            var visited = Set<ObjectIdentifier>()
            func find(_ element: NSObject) -> NSRect? {
                guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
                if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                   element.value(forKey: "accessibilityIdentifier") as? String == identifier,
                   element.responds(to: NSSelectorFromString("accessibilityFrame")) {
                    return (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
                }
                guard element.responds(to: NSSelectorFromString("accessibilityChildren")),
                      let children = element.value(forKey: "accessibilityChildren") as? [NSObject] else { return nil }
                for child in children {
                    if let frame = find(child) { return frame }
                }
                return nil
            }
            let frame = try #require(find(window), "Missing accessibility element \(identifier)")
            try #require(!frame.isEmpty)
            return frame
        }

        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        for _ in 0 ..< 3 { try await launcher.press(125) }
        try await capture("hint")
        try await launcher.press(124)
        #expect(model.launcherDraft.text == "git status --short")
        try await launcher.press(36)
        let presentation = try #require(model.launcherTerminal)
        let session = presentation.session
        process.emit(osc("7;" + project.absoluteString) + osc("133;A") + osc("133;B"))
        try await AskQuickSearchSessionTests.wait { session.git?.dirty == true }
        #expect(session.displayDirectory(session.cwd) == "~/Projects/typeflux")
        process.emit(osc("133;C") + " M Sources/Typeflux/Ask/AskComposerViews.swift\r\n")
        try await capture("inline")
        process.emit(osc("133;D;0") + osc("133;B"))
        presentation.fill("git diff --check")
        #expect(presentation.submit())
        process.emit(osc("133;C") + "Sources/Example.swift:12: trailing whitespace.\r\n" + osc("133;D;2") + osc("133;B"))
        presentation.select(-1)
        try await capture("session")
        let lastBlock = try #require(session.blocks.last)
        let blockIdentifier = "terminal.block.\(lastBlock.id)"
        let originalHeight = try accessibilityFrame(blockIdentifier).height
        presentation.fill("rm -rf build .build")
        #expect(!presentation.submit() && presentation.pendingRisk == .delete)
        try await capture("risk")
        let block = try accessibilityFrame(blockIdentifier)
        let card = try accessibilityFrame("terminal.risk.card")
        let viewport = try accessibilityFrame("terminal.blockList")
        #expect(!block.intersects(card) && block.minY >= card.maxY)
        #expect(viewport.insetBy(dx: -1, dy: -1).contains(block))
        #expect(block.height >= originalHeight - 1)
        guard folder != nil else { return }
        let writesBeforeCancel = process.writes.count
        try await terminalKey(53, [], in: window)
        #expect(presentation.pendingRisk == nil && session.blocks.last?.state == .cancelled)
        #expect(process.writes.count == writesBeforeCancel)
        presentation.fill("git sta")
        try await AskQuickSearchSessionTests.wait { (window.firstResponder as? NSTextView)?.string == "git sta" }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        try await terminalKey(48, [], in: window)
        #expect(presentation.text == "git stash" && presentation.completionCandidates == ["stash", "status"])
        try await capture("completion")
        try await terminalKey(48, [], in: window)
        #expect(presentation.text == "git status")

        presentation.fill("read response")
        #expect(presentation.submit())
        process.emit(osc("133;C") + "Continue? ")
        #expect(presentation.prompt == .input)
        #expect(session.liveOutputRows == 1)
        try await capture("stdin")
        #expect(session.terminalView.normalScreenText().contains("Continue?"))
        process.readsHiddenInput = true
        session.refreshInput()
        try await capture("password")
        model.foldLauncherKeyword()
        #expect(center.sessions.first === session)
        #expect(model.terminalHomeRows.first?.detail == "~/Projects/typeflux")
        try await capture("home")
        process.readsHiddenInput = false
        process.emit(osc("133;D;0") + osc("133;B"))
        model.resumeLauncherTerminal(session.id)
        model.moveLauncherTerminal {}
        try await capture("window", in: tabbedWindow.panel)
    }

    @Test(arguments: [true, false]) func `return modifiers choose window or external terminal`(inWindow: Bool) async throws {
        let dispatcher = TestTerminalDispatcher()
        let runner = TestTerminalRunner()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "cmd pwd", prepare: {
            $0.terminalCommandDispatcher = dispatcher
            $0.terminalRunnerOverride = runner
        })
        defer { launcher.close() }
        let model = launcher.fixture.model
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        try await launcher.press(36, inWindow ? .command : .option)
        try await AskQuickSearchSessionTests.wait { launcher.dismissed == 1 }
        if inWindow {
            #expect(runner.requests == [.init(command: "pwd", terminal: .terminal, builtin: .init())])
            #expect(dispatcher.requests.isEmpty)
        } else {
            #expect(dispatcher.requests == [.init(command: "pwd", terminal: .terminal)])
            #expect(runner.requests.isEmpty)
        }
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func `built-in submission validates the snapshot and needs no consent`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        let runner = TestTerminalRunner()
        model.terminalCommandDispatcher = dispatcher
        model.terminalRunnerOverride = runner
        _ = try await prepare(model, command: "ls -la", terminal: .iterm)
        let builtin = TerminalCommandRequest(command: "ls -la", terminal: .iterm, builtin: TerminalRunSettings())
        var forged = builtin
        forged.builtin = TerminalRunSettings(directory: "/etc")
        model.submitTerminalCommand(forged) { Issue.record("Forged settings ran") }
        #expect(runner.requests.isEmpty)
        var completed = 0
        model.submitTerminalCommand(builtin) { completed += 1 }
        #expect(runner.requests == [builtin] && completed == 1)
        #expect(dispatcher.authorizations.isEmpty && !model.terminalCommandSending && !model.plugins.isActive)
        let services = try #require(runner.services.first)
        #expect((services.dispatcher as? TestTerminalDispatcher) === dispatcher)
        model.submitTerminalCommand(builtin) { completed += 1 }
        #expect(runner.requests.count == 1 && completed == 1)
    }

    @Test func `repeated return and marked text never dispatch`() async throws {
        let dispatcher = TestTerminalDispatcher()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "cmd pwd", prepare: {
            $0.terminalCommandDispatcher = dispatcher
        })
        defer { launcher.close() }
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.plugins.isPlanCurrent }
        let repeated = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: launcher.window.windowNumber, context: nil,
                                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                                     isARepeat: true, keyCode: 36))
        launcher.editor.keyDown(with: repeated)
        #expect(dispatcher.requests.isEmpty)
        launcher.editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
        try await launcher.press(36)
        #expect(dispatcher.requests.isEmpty)
        launcher.editor.unmarkText()
    }

    @Test func `settings page explains conflicts without replacing user keywords`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let settings = fixture.model.modelLibrary.settings
        let keywords = [AskKeyword(keyword: "cmd", pluginID: AskWebSearchPlugin.id, aliases: [">"])]
        settings.saveAskLauncherKeywords(keywords)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-settings-\(UUID())")
        let workflows = AskWorkflowStore(settings: settings, root: root)
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let view = AskLauncherPluginSettingsView(settings: settings, workflows: workflows)
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 760, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        #expect(settings.askLauncherKeywords == keywords)
        let label = L("terminal.command.keywordConflict", "cmd, >")
        var seen = Set<ObjectIdentifier>()
        func containsLabel(_ node: Any) -> Bool {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return false }
            for attribute in ["accessibilityLabel", "accessibilityValue"] {
                if object.responds(to: NSSelectorFromString(attribute)),
                   object.value(forKey: attribute) as? String == label {
                    return true
                }
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")),
                  let children = object.value(forKey: "accessibilityChildren") as? [Any] else { return false }
            return children.contains(where: containsLabel)
        }
        #expect(containsLabel(window))
    }

    @Test func `terminal keyword editor renders in both appearances`() async throws {
        for dark in [false, true] {
            let view = AskKeywordEditorSheet(draft: .init(editing: AskTerminalCommandPlugin.keywords[0]),
                                             keywords: [], workflows: [], onSave: { _ in }, onCancel: {})
                .environment(\.colorScheme, dark ? .dark : .light)
            let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 560, height: 660),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 5000)
            if let path = ProcessInfo.processInfo.environment["TYPEFLUX_TERMINAL_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("terminal-settings-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
