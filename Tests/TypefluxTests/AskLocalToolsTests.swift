import Foundation
import Testing
@testable import Typeflux

@Suite("Ask browser adapter", .exclusiveUIState)
@MainActor
struct AskLocalToolsTests {
    @Test func workspaceDefinitionsAndRelativeWritesUseTheSameStableDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tool-workspace-" + UUID().uuidString)
        let suite = "tool-workspace-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        let downloadFolder = base.appendingPathComponent("a-Downloads")
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        let downloads = try AskSecureDirectory.openRoot(downloadFolder, create: false, privateRoot: false).url
        let settings = SettingsStore(defaults: defaults)
        settings.askFileAccessFolders = [downloads.path]
        settings.askCodeExecutionEnabled = true
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("z-workspaces"))
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults)),
                                  settings: settings, workspaces: store, owner: { "owner" })
        let definitions = await tools.definitions(conversationId: "website")
        let root = store.url(owner: "owner", conversationId: "website")
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(root.path > downloads.path)
        #expect(tools.fileTools(conversationId: "website").roots.first == root.path)
        let files = try #require(definitions.first { $0.name == "files" })
        #expect(files.description.contains("Conversation workspace (default working directory): " + root.path))
        let command = try #require(definitions.first { $0.name == "run_command" })
        #expect(command.description.contains("Current working directory (conversation workspace): " + root.path))
        #expect(!command.description.contains("starts in the user's home folder"))
        #expect(await tools.definitions(conversationId: "website").first { $0.name == "files" } == files)
        _ = try tools.fileTools(conversationId: "website").execute([
            "action": "write", "path": "work/site/index.html", "content": "<link rel='stylesheet' href='styles.css'>Ready"
        ])
        let output = try await AskHostCommand().run(
            command: "printf 'body{}' > work/site/styles.css; printf '%s' \"$TYPEFLUX_WORKSPACE\"", timeout: 5,
            workingDirectory: root)
        #expect(!output.isError)
        #expect(output.content.contains(root.path))
        #expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("work/site/index.html").path))
        let reopened = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("z-workspaces"))
        let listed = try await reopened.listFiles(owner: "owner", conversationId: "website")
        #expect(Set(listed.map(\.relativePath)) == ["work/site/index.html", "work/site/styles.css"])
        #expect(listed.allSatisfy { $0.size > 0 })
    }

    @Test func unavailableConfiguredWorkspaceDoesNotOfferHomeDirectoryFallback() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-workspace-" + UUID().uuidString)
        let suite = "blocked-workspace-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        try Data("not a directory".utf8).write(to: base)
        let settings = SettingsStore(defaults: defaults)
        settings.askFileAccessFolders = [FileManager.default.temporaryDirectory.path]
        settings.askCodeExecutionEnabled = true
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults)),
            settings: settings, workspaces: AskConversationWorkspaceStore(rootURL: base),
            commandJobs: try AskCommandJobStore(root: nil), owner: { "owner" })
        let definitions = await tools.definitions(conversationId: "website")
        let names = definitions.map(\.name)
        #expect(!names.contains("files"))
        #expect(!names.contains("run_command"))
        let jobs = try #require(definitions.first { $0.name == "command_job" })
        let schema = try #require(JSONSerialization.jsonObject(with: jobs.parameters.data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(action["enum"] as? [String] == ["status", "logs", "stop"])
    }

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
