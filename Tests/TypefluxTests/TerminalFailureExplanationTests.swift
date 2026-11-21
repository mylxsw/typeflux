import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite(.exclusiveUIState)
struct TerminalFailureExplanationTests {
    private struct Generator: AskStructuredTextGenerating {
        let respond: @Sendable (String) throws -> String

        func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
            try respond(userPrompt)
        }

        func stream(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error> {
            Issue.record("Expected structured generation")
            return AsyncThrowingStream { $0.finish() }
        }
    }

    private func failed() -> TerminalCommandBlock {
        var block = TerminalCommandBlock(command: "git status", cwd: "/private", startedAt: Date())
        block.endedAt = Date()
        block.state = .finished
        block.exitCode = 128
        block.output = NSAttributedString(string: "fatal: not a git repository")
        return block
    }

    private func isolated() -> TerminalFailureExplanation {
        TerminalFailureExplanation(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func disclosureAndBoundedContext() async throws {
        let model = isolated()
        var block = failed()
        let tail = String(repeating: "a", count: 4094)
        block.output = NSAttributedString(string: "omitted🔒" + tail)
        model.generator = Generator { context in
            #expect(context == "Command: git status\nExit code: 128\nOutput:\n" + tail)
            return #"{"explanation":"  Wrong directory. ","command":"pwd"}"#
        }
        #expect(model.explain(block) == nil && model.phase == .disclosure)
        let task = try #require(model.explain(block, consent: true))
        #expect(model.phase == .loading)
        await task.value
        #expect(model.phase == .ready(.init(explanation: "Wrong directory.", command: "pwd")))
        var draft = ""
        model.openAsk = { draft = $0 }
        model.continueInAsk(block)
        #expect(draft == "Command: git status\nExit code: 128\nOutput:\n" + tail + "\n\nWrong directory.\n\npwd")
        block.hadHiddenInput = true
        #expect(model.explain(block) == nil)
        draft = ""
        model.continueInAsk(block)
        #expect(draft.isEmpty)
    }

    @Test func clearedRequestCannotRestoreAnOldCard() async throws {
        let model = isolated()
        let block = failed()
        model.generator = Generator { _ in #"{"explanation":"Try again.","command":"pwd"}"# }
        let task = try #require(model.explain(block, consent: true))
        #expect(model.explain(block) != nil && model.phase == .loading)
        model.clear()
        await task.value
        #expect(model.blockID == nil && model.phase != .ready(.init(explanation: "Try again.", command: "pwd")))
    }

    @Test func onlyCompletedFailuresAreEligible() {
        var block = failed()
        #expect(block.canExplain)
        block.exitCode = 0
        #expect(!block.canExplain)
        block.exitCode = 130
        block.state = .interrupted
        #expect(!block.canExplain)
        block.state = .running
        block.endedAt = nil
        #expect(!block.canExplain)
    }

    @Test func disclosureAndOfflineRetryButtons() async throws {
        let model = isolated()
        let block = failed()
        model.generator = Generator { _ in throw URLError(.notConnectedToInternet) }
        model.explain(block)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let card = TerminalExplanationCard(explanation: model, block: block, canFill: true, fill: {})
        let host = NSHostingView(rootView: card.frame(width: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        func press(_ identifier: String) async throws {
            var visited = Set<ObjectIdentifier>()
            func findButton(_ node: NSObject) -> NSObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                   node.value(forKey: "accessibilityIdentifier") as? String == identifier { return node }
                guard node.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
                for child in node.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] {
                    if let match = findButton(child) { return match }
                }
                return nil
            }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let button = try #require(findButton(window), "Missing button \(identifier)")
            button.perform(NSSelectorFromString("accessibilityPerformPress"))
        }
        try await press("terminal.ai.consent")
        try await AskQuickSearchSessionTests.wait { model.phase == .offline }
        model.generator = Generator { _ in #"{"explanation":"Try again.","command":"pwd"}"# }
        try await press("terminal.ai.retry")
        try await AskQuickSearchSessionTests.wait {
            model.phase == .ready(.init(explanation: "Try again.", command: "pwd"))
        }
    }

    @Test func errorsAndRetry() async {
        let model = isolated()
        let block = failed()
        #expect(model.explain(block, consent: true) == nil && model.phase == .failed)
        model.generator = Generator { _ in throw URLError(.notConnectedToInternet) }
        await model.explain(block)?.value
        #expect(model.phase == .offline)
        for response in ["{}", #"{"explanation":" ","command":"ls"}"#,
                         #"{"explanation":"Retry","command":"ls\nwhoami"}"#] {
            model.generator = Generator { _ in response }
            await model.explain(block)?.value
            #expect(model.phase == .failed)
        }
        model.clear()
        #expect(model.blockID == nil)
    }

    @Test func suggestionsFillAnIdlePromptWithoutWritingToTheShell() async throws {
        let process = FakeTerminalProcess()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let history = TerminalCommandHistory(defaults: defaults)
        let center = TerminalSessionCenter(history: history, makeProcess: { process })
        let session = try center.create(settings: .init(directory: "/tmp"))
        defer { center.terminateAll() }
        let explanation = isolated()
        let model = TerminalLauncherModel(session: session, settings: .init(), source: nil,
                                          notify: { _, _ in false }, visible: { true }, explanation: explanation)
        process.emit("\u{1b}]133;A\u{7}\u{1b}]133;B\u{7}")
        #expect(session.submit("git status"))
        process.emit("\u{1b}]133;C\u{7}fatal: not a git repository\r\n\u{1b}]133;D;128\u{7}\u{1b}]133;B\u{7}")
        let block = try #require(session.blocks.last)
        explanation.generator = Generator { _ in
            #"{"explanation":"The current directory is outside a Git repository.","command":"pwd"}"#
        }
        await explanation.explain(block, consent: true)?.value
        let writes = process.writes
        model.select(-1)
        #expect(model.canTabToExplanation)
        try await renderPreview(model, session: session)
        #expect(model.complete() && model.text == "pwd")
        model.fill("")
        #expect(model.fillExplanation())
        #expect(model.text == "pwd" && process.writes == writes && session.blocks.count == 1)
        model.clear()
        #expect(!model.fillExplanation())
    }

    private func renderPreview(_ model: TerminalLauncherModel, session: TerminalSession) async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_TERMINAL_AI_PREVIEWS"] else { return }
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for scheme in [ColorScheme.light, .dark] {
            let view = TerminalLauncherView(model: model, session: session, sessions: [session],
                                            select: { _ in }, new: {}, close: {}, move: {}, dismiss: {},
                                            insert: { _ in }, commands: { [] }, error: { _ in })
                .frame(width: 660, height: 260)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = CGRect(x: 0, y: 0, width: 660, height: 260)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = scheme == .dark ? "dark.png" : "light.png"
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
        }
    }
}
