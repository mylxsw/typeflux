import Foundation
import Testing
@testable import Typeflux

private final class AskScriptRunner: ProcessCommandRunning {
    var scripts: [String] = []
    var failure: (any Error)?
    func run(executablePath: String, arguments: [String], environment: [String: String]?, currentDirectoryURL: URL?) async throws -> ProcessCommandResult {
        #expect(executablePath == "/usr/bin/osascript")
        #expect(arguments.first == "-e")
        scripts.append(arguments[1])
        if let failure { throw failure }
        return .init(stdout: "Observed page", stderr: "", exitCode: 0)
    }
}

@Suite("Ask browser adapter")
@MainActor
struct AskLocalToolsTests {
    @Test func scriptsValidateDestinationsAndKeepUserContentQuoted() throws {
        let read = try AskLocalTools.browserScript(["action": "read"], bundle: "com.apple.Safari")
        #expect(read.contains("do JavaScript")); #expect(read.contains("document.body.innerText"))
        let chrome = try AskLocalTools.browserScript(["action": "read"], bundle: "com.google.Chrome")
        #expect(chrome.contains("execute active tab of front window"))
        let open = try AskLocalTools.browserScript(["action": "open", "url": "https://example.com/?q=test"], bundle: "com.apple.Safari")
        #expect(open.contains("Navigation requested"))
        let click = try AskLocalTools.browserScript(["action": "click", "selector": "button"], bundle: "com.apple.Safari")
        #expect(click.contains("e.click()"))
        let fill = try AskLocalTools.browserScript(["action": "fill", "selector": "textarea", "text": "\";do shell script \"bad\"\n"], bundle: "com.apple.Safari")
        #expect(fill.contains("dispatchEvent"))
        #expect(fill.components(separatedBy: "\n").count == 5)
        let invalidArguments: [[String: Any]] = [[:], ["action": "delete"], ["action": "open", "url": "javascript:alert(1)"], ["action": "open", "url": "file:///etc/passwd"], ["action": "fill", "selector": "input"], ["action": "click"], ["action": "fill", "selector": "input", "text": String(repeating: "a", count: 10001)]]
        for invalid in invalidArguments {
            #expect(throws: (any Error).self) { try AskLocalTools.browserScript(invalid, bundle: "com.apple.Safari") }
        }
        #expect(throws: (any Error).self) { try AskLocalTools.browserScript(["action": "read"], bundle: "arbitrary.app") }
    }

    @Test func browserResultsAndFailuresUseInjectedProcessBoundary() async throws {
        let suite = "ask-tools-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults))
        let runner = AskScriptRunner()
        let tools = AskLocalTools(registry: registry, runner: runner)
        #expect(await tools.definitions().map(\.name) == ["computer", "browser"])
        let output = try await tools.executeBrowser(["action": "read"], bundle: "com.apple.Safari")
        #expect(output.content == "Observed page")
        runner.failure = AskLocalError.message("Automation denied")
        await #expect(throws: (any Error).self) { try await tools.executeBrowser(["action": "read"], bundle: "com.google.Chrome") }
        runner.failure = CancellationError()
        await #expect(throws: CancellationError.self) { try await tools.executeBrowser(["action": "read"], bundle: "com.apple.Safari") }
        tools.bindConversation("missing-target")
        await #expect(throws: (any Error).self) {
            try await tools.execute(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)), conversationId: "missing-target")
        }
        await #expect(throws: (any Error).self) {
            try await tools.execute(.init(id: "call", function: .init(name: "missing_tool", arguments: #"{"action":"read"}"#)), conversationId: "missing-target")
        }
        #expect(runner.scripts.count == 3)
    }
}
