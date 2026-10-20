import AppKit
import Carbon
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
final class TestTerminalDispatcher: TerminalCommandDispatching {
    var authorizations: [TerminalApplication] = []
    var requests: [TerminalCommandRequest] = []
    var authorizationError: TerminalCommandError?
    var sendError: TerminalCommandError?
    var pauseAuthorization = false
    var authorization: CheckedContinuation<Void, Never>?
    var pauseSend = false
    var sending: CheckedContinuation<Void, Never>?

    func authorize(_ terminal: TerminalApplication) async throws {
        authorizations.append(terminal)
        if pauseAuthorization {
            await withCheckedContinuation { authorization = $0 }
        }
        if let authorizationError {
            throw authorizationError
        }
    }

    func send(_ request: TerminalCommandRequest) async throws {
        requests.append(request)
        if pauseSend {
            await withCheckedContinuation { sending = $0 }
        }
        if let sendError {
            throw sendError
        }
    }
}

final class TestTerminalAutomationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var calls: [String] {
        lock.withLock { values }
    }

    func record(_ value: String) {
        lock.withLock { values.append(value) }
    }
}

@Suite("Launcher terminal commands", .exclusiveUIState)
@MainActor
struct TerminalCommandTests {
    private func input(_ text: String, terminal: TerminalApplication = .terminal) -> AskPluginRequest {
        .init(text: text, origin: .argument, keyword: AskTerminalCommandPlugin.keywords[0],
              options: [AskTerminalCommandPlugin.terminalOption: terminal.rawValue], interfaceLanguage: .english)
    }

    func prepare(_ model: AskConversationModel, command: String = "pwd",
                 terminal: TerminalApplication = .terminal) async throws -> TerminalCommandRequest {
        var keyword = AskTerminalCommandPlugin.keywords[0]
        keyword.options = [AskTerminalCommandPlugin.terminalOption: terminal.rawValue]
        model.modelLibrary.settings.saveAskLauncherKeywords([keyword])
        model.plugins.enter(keyword)
        model.launcherDraft.text = command
        model.plugins.update(text: command, selection: nil, language: .english)
        try await AskQuickSearchSessionTests.wait { model.plugins.isPlanCurrent }
        return .init(command: command, terminal: terminal)
    }

    @Test func `primary and alias preserve shell text`() throws {
        let text = " printf '%s\\n' \"中文 $HOME\" | wc -l  "
        for word in ["cmd", ">"] {
            let match = try #require(AskKeywordMatcher.match(
                word + " " + text,
                keywords: AskTerminalCommandPlugin.keywords
            ))
            guard case let .active(keyword, argument) = match else { Issue.record("Missing command match"); return }
            #expect(keyword.keyword == "cmd")
            #expect(keyword.aliases == [">"])
            #expect(argument == text)
        }
        #expect(AskKeywordMatcher.match("cmdlet pwd", keywords: AskTerminalCommandPlugin.keywords) == nil)
        #expect(AskKeywordMatcher.match(">pwd", keywords: AskTerminalCommandPlugin.keywords) == nil)
        #expect(AskKeywordMatcher.match("fy   hello  ", keywords: AskTranslatePlugin.keywords)
            == .active(AskTranslatePlugin.keywords[0], argument: "hello  "))
    }

    @Test func `validates before providing any execution action`() async {
        let plugin = AskTerminalCommandPlugin()
        for text in ["", " \t ", "pwd\n", "pwd\rdate", "echo\u{0}", "pwd\u{1B}[2J", "pwd\u{2028}date",
                     String(repeating: "a", count: TerminalCommandRequest.maximumBytes + 1)] {
            #expect(TerminalCommandRequest.problem(with: text) != nil)
            #expect(await plugin.plan(input(text)).actions.isEmpty)
        }
        #expect(TerminalCommandRequest.problem(with: String(
            repeating: "a",
            count: TerminalCommandRequest.maximumBytes
        )) == nil)
        #expect(TerminalCommandRequest.problem(with: String(repeating: "中", count: 6000)) != nil)
        var request = input("pwd")
        request.options = [AskTerminalCommandPlugin.terminalOption: "other"]
        #expect(await plugin.plan(request).actions.isEmpty)
        #expect(TerminalApplication.configured(in: [:]) == .terminal)
        #expect(TerminalApplication.iterm.bundleID == "com.googlecode.iterm2")
        #expect(TerminalApplication.terminal.bundleID == "com.apple.Terminal")
    }

    @Test func `planning and plugin run cannot execute`() async throws {
        let plugin = AskTerminalCommandPlugin()
        for terminal in TerminalApplication.allCases {
            let request = input("  echo 'hello'  ", terminal: terminal)
            let plan = await plugin.plan(request)
            #expect(plan.mode == .onSubmit)
            #expect(plan.action(for: .enter)?.kind == .terminalCommand(.init(
                command: request.text,
                terminal: terminal
            )))
            #expect(plan.action(for: .commandC)?.kind == .copy(request.text))
            #expect(plugin.chipDetail(for: request.keyword, language: .english) == "Terminal")
            #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
            do {
                _ = try await plugin.run(request, plan: plan) { _ in }
                Issue.record("Plugin run must not execute")
            } catch let failure as AskPluginFailure { #expect(!failure.retry) }
        }
        #expect(!plugin.usesSelectionInput && plugin.preservesInputWhitespace && plugin.entersOnReturn)
        #expect(!plugin.placeholder(selectionLines: 1).isEmpty)
        #expect(plugin.symbol == "terminal" && plugin.id == AskTerminalCommandPlugin.id)
        #expect(plugin.defaultKeywords == AskTerminalCommandPlugin.keywords)
    }

    @Test func `session ignores selection and automatic runs`() async throws {
        let session = AskPluginSession(plugins: [AskTerminalCommandPlugin()]) { AskTerminalCommandPlugin.keywords }
        let raw = "  echo \"$HOME\"  "
        #expect(session.detect(in: "cmd " + raw) == raw)
        session.update(text: "", selection: "rm file", language: .english, runWhenPlanned: true)
        #expect(session.request == nil)
        session.update(text: raw, selection: "wrong", language: .english, runWhenPlanned: true)
        try await AskQuickSearchSessionTests.wait { session.isPlanCurrent }
        #expect(session.request?.text == raw && session.request?.selection == nil)
        #expect(!session.isRunning && !session.run())
        session.rerun(with: [:], selection: nil, text: raw, language: .english)
        try await AskQuickSearchSessionTests.wait { session.isPlanCurrent }
        #expect(!session.isRunning)
    }

    @Test func `migration preserves conflicts and disabled keywords`() {
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskTerminalCommandPlugin.id }
        let custom = AskKeyword(keyword: "cmd", pluginID: "workflow.custom")
        let upgraded = AskPluginRegistry.keywords(saved: [custom], known: known)
        #expect(upgraded.contains(custom))
        #expect(upgraded.first { $0.pluginID == AskTerminalCommandPlugin.id }?.allKeywords == [">"])
        let both = AskPluginRegistry.keywords(saved: [custom, .init(keyword: ">", pluginID: "web")], known: known)
        #expect(!both.contains { $0.pluginID == AskTerminalCommandPlugin.id })
        let reserved = AskPluginRegistry.keywords(saved: [], known: known, reserved: [">"])
        #expect(reserved.first { $0.pluginID == AskTerminalCommandPlugin.id }?.allKeywords == ["cmd"])
        var disabled = AskTerminalCommandPlugin.keywords[0]
        disabled.enabled = false
        #expect(AskPluginRegistry.keywords(saved: [disabled], known: AskPluginRegistry.coveredGroups) == [disabled])
        #expect(AskKeywordMatcher.match("> pwd", keywords: [disabled]) == nil)
        #expect(AskTerminalCommandPlugin.conflicts(in: [custom], workflows: []) == ["cmd"])
        #expect(AskTerminalCommandPlugin.conflicts(in: AskTerminalCommandPlugin.keywords, workflows: []) == [])
        #expect(AskTerminalCommandPlugin.conflicts(in: [], workflows: [
            .init(keyword: ">", workflowID: "custom", workflowName: "Custom", enabled: false)
        ]) == [">"])
    }

    @Test func `settings round trip target and aliases`() {
        var draft = AskKeywordDraft(editing: AskTerminalCommandPlugin.keywords[0])
        #expect(draft.kind == .terminal && draft.terminal == .terminal)
        draft.terminal = .iterm
        let keyword = draft.result()
        #expect(keyword.aliases == [">"])
        #expect(AskKeywordDraft(editing: keyword).terminal == .iterm)
        #expect(draft.canSave(among: [], workflows: []))
        #expect(AskKeywordKind.terminal.pluginID == AskTerminalCommandPlugin.id)
        #expect(AskKeywordKind.terminal.symbol == "terminal")
        #expect(!draft.displayName.isEmpty && draft.titlePlaceholder.isEmpty)
        #expect(!AskKeywordKind.terminal.hint.hasPrefix("ask."))
        #expect(AskKeywordSection.system.kinds.contains(.terminal))
        let row = AskKeywordListPresentation.row(keyword, kind: .terminal, interface: .english, secondLanguage: "ja")
        #expect(row.summary.contains("iTerm2"))
        var added = AskKeywordDraft(adding: .terminal)
        added.keyword = "shell"
        #expect(added.result().pluginID == AskTerminalCommandPlugin.id)
    }

    @Test func `native event keeps untrusted text as data`() throws {
        let command = "  echo \"$HOME\"; ' & return & '\\中文  "
        let event = TerminalCommandDispatcher.event(command: command)
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.atIndex(1)?.stringValue == command)
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyASSubroutineName))?.stringValue == "dispatchcommand")
        let script =
            try #require(
                NSAppleScript(source: "on dispatchcommand(commandText)\nreturn commandText\nend dispatchcommand")
            )
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        #expect(error == nil && result.stringValue == command)
        for terminal in TerminalApplication.allCases {
            let source = TerminalCommandDispatcher.source(for: terminal)
            #expect(source.contains("with timeout of 15 seconds"))
            #expect(!source.contains(command))
            #expect(source.contains(terminal.bundleID))
            #expect(!source.contains("sh -c") && !source.contains("default profile command"))
        }
        let native = try #require(NSAppleScript(source: TerminalCommandDispatcher.source(for: .terminal)))
        #expect(native.compileAndReturnError(&error))
    }

    @Test func `native compiler and event boundary reports exact failure categories`() throws {
        let command = "  echo \"$HOME\"; ' & return & '\\中文  "
        let echo = NSAppleScript(source: "on dispatchcommand(commandText)\nreturn commandText\nend dispatchcommand")
        #expect(try TerminalCommandDispatcher.runScript(echo, command: command).stringValue == command)
        #expect(throws: TerminalCommandError.unavailable) {
            _ = try TerminalCommandDispatcher.runScript(nil, command: command)
        }
        #expect(throws: TerminalCommandError.unavailable) {
            _ = try TerminalCommandDispatcher.runScript(NSAppleScript(source: "on dispatchcommand("), command: command)
        }
        let failing =
            NSAppleScript(
                source: "on dispatchcommand(commandText)\nerror \"fixture\" number -1712\nend dispatchcommand"
            )
        #expect(throws: TerminalCommandError.uncertain) {
            _ = try TerminalCommandDispatcher.runScript(failing, command: command)
        }
    }

    @Test func `default application lookup is read only when launch and consent are substituted`() async throws {
        let capture = TestTerminalAutomationCapture()
        let dispatcher = TerminalCommandDispatcher(launch: { _ in capture.record("launch") },
                                                   consent: { capture.record($0.rawValue) },
                                                   execute: { _ in Issue.record("Unexpected execution") })
        try await dispatcher.authorize(.terminal)
        #expect(capture.calls == ["launch", "terminal"])
    }

    @Test func `help demonstrates a typed shell command rather than selection execution`() {
        let keyword = HelpKeyword(keyword: AskTerminalCommandPlugin.keywords[0], title: "Terminal Command",
                                  detail: "", symbol: "terminal", group: .tools, unavailableReason: nil,
                                  shortcut: nil, usageCount: 0, isBuiltIn: true, usesSelection: false)
        #expect(HelpKeywordDetail.exampleArgument(keyword) == "pwd")
        #expect(HelpKeywordDetail.examples(keyword) == ["cmd pwd"])
    }

    @Test func `adapter preflights and sends exactly once`() async throws {
        let capture = TestTerminalAutomationCapture()
        let url = URL(fileURLWithPath: "/Applications/TestTerminal.app")
        let dispatcher = TerminalCommandDispatcher(applicationURL: { _ in url }, launch: { launched in
            #expect(launched == url)
            capture.record("launch")
        }, consent: { capture.record($0.rawValue) }, execute: { capture.record($0.command) })
        try await dispatcher.authorize(.iterm)
        try await dispatcher.send(.init(command: "  pwd  ", terminal: .iterm))
        #expect(capture.calls == ["launch", "iterm", "  pwd  "])
    }

    @Test func `adapter does not fallback after failures`() async throws {
        let absent = TerminalCommandDispatcher(
            applicationURL: { _ in nil },
            launch: { _ in Issue.record("Unexpected launch") },
            consent: { _ in Issue.record("Unexpected consent") },
            execute: { _ in Issue.record("Unexpected execution") }
        )
        await #expect(throws: TerminalCommandError.self) { try await absent.authorize(.iterm) }
        let capture = TestTerminalAutomationCapture()
        let url = URL(fileURLWithPath: "/Applications/TestTerminal.app")
        let launchFailure = TerminalCommandDispatcher(applicationURL: { _ in url }, launch: { _ in
            throw TerminalCommandError.unavailable
        }, consent: { _ in Issue.record("Unexpected consent") }, execute: { _ in Issue.record("Unexpected execution") })
        await #expect(throws: TerminalCommandError.self) { try await launchFailure.authorize(.terminal) }
        let denied = TerminalCommandDispatcher(applicationURL: { _ in url }, launch: { _ in }, consent: { _ in
            throw TerminalCommandError.permissionDenied
        }, execute: { _ in Issue.record("Unexpected execution") })
        await #expect(throws: TerminalCommandError.self) { try await denied.authorize(.terminal) }
        let uncertain = TerminalCommandDispatcher(applicationURL: { _ in url }, launch: { _ in }, consent: { _ in },
                                                  execute: { _ in
                                                      capture.record("send")
                                                      throw TerminalCommandError.uncertain
                                                  })
        await #expect(throws: TerminalCommandError.self) {
            try await uncertain.send(.init(command: "pwd", terminal: .terminal))
        }
        #expect(capture.calls == ["send"])
        await #expect(throws: TerminalCommandError.self) {
            try await uncertain.send(.init(command: "pwd\n", terminal: .terminal))
        }
        #expect(capture.calls == ["send"])
        for error in [TerminalCommandError.notInstalled, .permissionDenied, .unavailable, .uncertain] {
            #expect(!error.localizedDescription.isEmpty && !error.localizedDescription.contains("terminal.command."))
        }
    }
}
