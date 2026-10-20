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
        #expect(model.plugins.plan?.action(for: .optionEnter)?.kind == .terminalAutomationSettings)
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
        let runner = TestTerminalRunner()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: word + " pwd", prepare: {
            $0.terminalCommandDispatcher = dispatcher
            $0.terminalRunner = runner
        })
        defer { launcher.close() }
        let model = launcher.fixture.model
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        #expect(dispatcher.requests.isEmpty && runner.requests.isEmpty)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_TERMINAL_SNAPSHOTS"], word == "cmd",
           let view = launcher.window.contentView {
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("terminal-launcher.png"))
        }
        try await launcher.press(15, .command)
        #expect(dispatcher.requests.isEmpty && runner.requests.isEmpty)
        #expect(await launcher.fixture.api.sends.isEmpty)
        try await launcher.press(53)
        #expect(model.launcherDraft.text.isEmpty && !model.plugins.isActive)
        #expect(model.launcherInputHistory.history.entries.isEmpty)
        model.launcherDraft.text = word + " pwd"
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        try await launcher.press(36)
        try await AskQuickSearchSessionTests.wait { !runner.requests.isEmpty }
        #expect(runner.requests == [.init(command: "pwd", terminal: .terminal, builtin: TerminalRunSettings())])
        #expect(dispatcher.requests.isEmpty && dispatcher.authorizations.isEmpty)
        #expect(launcher.dismissed == 1 && !model.plugins.isActive)
        #expect(model.launcherInputHistory.history.entries.isEmpty)
    }

    @Test func `command return runs the other way`() async throws {
        let dispatcher = TestTerminalDispatcher()
        let runner = TestTerminalRunner()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "cmd pwd", prepare: {
            $0.terminalCommandDispatcher = dispatcher
            $0.terminalRunner = runner
        })
        defer { launcher.close() }
        let model = launcher.fixture.model
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        try await launcher.press(36, .command)
        try await AskQuickSearchSessionTests.wait { !dispatcher.requests.isEmpty }
        #expect(dispatcher.requests == [.init(command: "pwd", terminal: .terminal)])
        #expect(runner.requests.isEmpty && launcher.dismissed == 1)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func `built-in submission validates the snapshot and needs no consent`() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let dispatcher = TestTerminalDispatcher()
        let runner = TestTerminalRunner()
        model.terminalCommandDispatcher = dispatcher
        model.terminalRunner = runner
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
