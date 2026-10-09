import Foundation
import Testing
@testable import Typeflux

@Suite("Ask browser adapter", .exclusiveUIState)
@MainActor
struct AskLocalToolsTests {
    @Test func scriptsValidateDestinationsAndKeepUserContentQuoted() throws {
        let quoted = "\";do shell script \"bad\"\n"
        let command = try AskBrowserExecutor.command(["action": "fill", "selector": "textarea", "text": quoted])
        let decoded = try JSONSerialization.jsonObject(with: Data(command.utf8)) as! [String: Any]
        #expect(decoded["text"] as? String == quoted)
        let source = AskBrowserExecutor.appleScript(bundle: "com.apple.Safari", expected: "1\u{1f}2\u{1f}https://example.com\u{1f}3",
                                                     javascript: AskBrowserExecutor.actionScript(id: "version", command: command))
        #expect(source.contains("do JavaScript")); #expect(source.contains("in approvedTab"))
        #expect(!source.contains("\n\";do shell script"))
        for invalid: [String: Any] in [[:], ["action": "delete"], ["action": "open", "url": "javascript:alert(1)"],
                                       ["action": "open", "url": "file:///etc/passwd"], ["action": "fill", "selector": "input"],
                                       ["action": "click"], ["action": "fill", "selector": "input", "text": String(repeating: "a", count: 10001)]] {
            #expect(throws: AskObservationError.invalid) { try AskBrowserExecutor.command(invalid) }
        }
    }

    @Test func browserResultsAndFailuresUseInjectedProcessBoundary() async throws {
        let suite = "ask-tools-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults))
        let runner = ObservationScriptRunner()
        let tools = AskLocalTools(registry: registry, runner: runner)
        tools.runningBundleIdentifiers = { [] }
        // Without Safari or Chrome the browser tool would always fail, so it is not offered.
        #expect(await !tools.definitions(conversationId: nil).map(\.name).contains("browser"))
        #expect(await tools.definitions(conversationId: "unbound").map(\.name).first == "computer")
        #expect(AskLocalTools.isSupportedBrowser("com.apple.Safari"))
        #expect(AskLocalTools.isSupportedBrowser("com.google.Chrome"))
        #expect(!AskLocalTools.isSupportedBrowser("com.apple.TextEdit"))
        #expect(!AskLocalTools.isSupportedBrowser(nil))
        tools.browserExecutor.processInstance = { _ in "42:1" }
        tools.runningBundleIdentifiers = { ["com.apple.Safari"] }
        let read = AskToolCall(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        let output = try await tools.execute(read, conversationId: "c")
        #expect(output.observation?.browserId == "com.apple.Safari")
        runner.failure = AskLocalError.message("Automation denied")
        await #expect(throws: (any Error).self) { try await tools.execute(read, conversationId: "c") }
        runner.failure = CancellationError()
        await #expect(throws: CancellationError.self) { try await tools.execute(read, conversationId: "c") }
        tools.runningBundleIdentifiers = { [] }
        tools.bindConversation("missing-target")
        await #expect(throws: (any Error).self) {
            try await tools.execute(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)), conversationId: "missing-target")
        }
        await #expect(throws: (any Error).self) {
            try await tools.execute(.init(id: "call", function: .init(name: "missing_tool", arguments: #"{"action":"read"}"#)), conversationId: "missing-target")
        }
        #expect(runner.scripts.count == 5)
    }
}
