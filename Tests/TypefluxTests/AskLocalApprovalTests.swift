import AppKit
import Testing
@testable import Typeflux

@Suite("Ask local authorization evidence")
@MainActor
struct AskLocalApprovalTests {
    func call(_ name: String, _ args: [String: Any]) throws -> AskToolCall {
        .init(id: "call", function: .init(name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)))
    }

    func registry() -> MCPRegistry {
        MCPRegistry(settingsStore: .init(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    @Test func filesBindCanonicalPathVersionAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.askFileAccessFolders = [root.path]
        let tools = AskLocalTools(registry: registry(), settings: settings)
        let read = try call("files", ["action": "read", "path": "./link"])
        let approved = try await tools.approvalBinding(for: read, conversationId: "c")
        #expect(approved.target.path == first.resolvingSymlinksInPath().path)
        #expect(approved.allowsReuse)
        var authorizations = 0
        let result = try await tools.executeApproved(read, conversationId: "c", binding: approved) { authorizations += 1 }
        #expect(result.content.contains("first")); #expect(authorizations == 1)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        await #expect(throws: (any Error).self) { try await tools.executeApproved(read, conversationId: "c", binding: approved, authorize: {}) }
        let write = try call("files", ["action": "write", "path": "created.txt", "content": "new"])
        let writeBinding = try await tools.approvalBinding(for: write, conversationId: "c")
        _ = try await tools.executeApproved(write, conversationId: "c", binding: writeBinding, authorize: {})
        #expect(try String(contentsOf: root.appendingPathComponent("created.txt")) == "new")
        let changed = try await tools.approvalBinding(for: write, conversationId: "c")
        #expect(changed.target.version != writeBinding.target.version)
        await #expect(throws: (any Error).self) {
            try await tools.executeApproved(write, conversationId: "c", binding: changed) {
                try Data("external update".utf8).write(to: root.appendingPathComponent("created.txt"))
            }
        }
        #expect(try String(contentsOf: root.appendingPathComponent("created.txt")) == "external update")
        settings.askFileAccessFolders = []
        await #expect(throws: (any Error).self) { try await tools.approvalBinding(for: read, conversationId: "c") }
    }

    @Test func attachedFoldersStayScopedThroughApprovalAndDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("attached.txt")
        try Data("attached content".utf8).write(to: file)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let grants = AskFolderGrants(defaults: defaults)
        let tools = AskLocalTools(registry: registry(), settings: SettingsStore(defaults: defaults), folderGrants: grants)
        let read = try call("files", ["action": "read", "path": file.path])
        await #expect(throws: (any Error).self) { try await tools.approvalBinding(for: read, conversationId: "c1") }
        tools.grantFolders([root.path], conversationId: "c1")
        let approved = try await tools.approvalBinding(for: read, conversationId: "c1")
        #expect(approved.target.path == file.resolvingSymlinksInPath().path)
        let raw = try await tools.execute(read, conversationId: "c1")
        let result = try await tools.executeApproved(read, conversationId: "c1", binding: approved, authorize: {})
        #expect(result.content == raw.content)
        #expect(result.content.contains("attached content"))
        await #expect(throws: (any Error).self) {
            try await tools.executeApproved(read, conversationId: "c2", binding: approved, authorize: {})
        }
        // Changing even an unrelated root changes the advertised capability and invalidates approval.
        tools.grantFolders([root.appendingPathComponent("extra").path], conversationId: "c1")
        let changed = try await tools.approvalBinding(for: read, conversationId: "c1")
        #expect(changed.target == approved.target)
        #expect(changed.toolVersion != approved.toolVersion)
        await #expect(throws: (any Error).self) {
            try await tools.executeApproved(read, conversationId: "c1", binding: approved, authorize: {})
        }
        grants.revoke("c1")
        await #expect(throws: (any Error).self) {
            try await tools.executeApproved(read, conversationId: "c1", binding: changed, authorize: {})
        }
    }

    @Test func browserRechecksDocumentAndPinsApprovedTab() async throws {
        let runner = ObservationScriptRunner(), browser = AskLocalTools(registry: registry(), runner: runner)
        browser.browserExecutor.writesEnabled = true
        browser.browserExecutor.processInstance = { _ in "42:1" }
        browser.runningBundleIdentifiers = { ["com.google.Chrome"] }
        let snapshot = try call("browser", ["action": "snapshot"])
        let observed = try await browser.execute(snapshot, conversationId: "c")
        let id = try #require(observed.observation?.id)
        let action = try call("browser", ["action": "open", "url": "https://destination.invalid/path", "observation_id": id])
        let approved = try await browser.approvalBinding(for: action, conversationId: "c")
        #expect(approved.target.domain == "example.invalid")
        #expect(approved.summary.contains("destination.invalid")); #expect(!approved.allowsReuse)
        let stamp = runner.stamp
        runner.stamp += "changed"
        await #expect(throws: (any Error).self) { try await browser.executeApproved(action, conversationId: "c", binding: approved, authorize: {}) }
        runner.stamp = stamp
        _ = try await browser.executeApproved(action, conversationId: "c", binding: approved, authorize: {})
        let dispatched = try #require(runner.scripts.last)
        #expect(dispatched.contains("if stamp is not")); #expect(dispatched.contains("if(location.href!=="))
        #expect(dispatched.contains("String(performance.timeOrigin)!=="))
        #expect(dispatched.contains("execute approvedTab javascript"))
        #expect(!dispatched.contains("execute active tab of front window"))
        await #expect(throws: (any Error).self) { try await browser.executeApproved(action, conversationId: "c", binding: approved, authorize: {}) }
        runner.stamp = "invalid snapshot"
        await #expect(throws: (any Error).self) { try await browser.approvalBinding(for: snapshot, conversationId: "c") }
    }

    @Test func memorySkillAndCodeBindingsAreLocalEvidence() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"))
        var owner = "account-1"
        let tools = AskLocalTools(registry: registry(), settings: settings, notes: notes, owner: { owner })
        let remember = try call("memory", ["action": "remember", "text": "Prefers tea"])
        let approved = try await tools.approvalBinding(for: remember, conversationId: "c")
        _ = try await tools.executeApproved(remember, conversationId: "c", binding: approved, authorize: {})
        #expect(notes.list(owner: owner).count == 1)
        owner = "account-2"
        await #expect(throws: (any Error).self) { try await tools.executeApproved(remember, conversationId: "c", binding: approved, authorize: {}) }
        #expect(notes.list(owner: owner).isEmpty)
        let skill = try call("skill", ["name": "email-reply"])
        let skillBinding = try await tools.approvalBinding(for: skill, conversationId: "c")
        #expect(!skillBinding.allowsReuse)
        _ = try await tools.executeApproved(skill, conversationId: "c", binding: skillBinding, authorize: {})
        settings.askCodeExecutionEnabled = false
        let code = try call("run_code", ["language": "python", "code": "print(1)"])
        await #expect(throws: (any Error).self) { try await tools.approvalBinding(for: code, conversationId: "c") }
        settings.askCodeExecutionEnabled = true
        // P01 may disable the sandbox on hosts that cannot enforce its process contract.
        if tools.sandbox.definition() != nil {
            let codeBinding = try await tools.approvalBinding(for: code, conversationId: "c")
            #expect(!codeBinding.allowsReuse); #expect(codeBinding.target.id == "c")
        }
        await #expect(throws: (any Error).self) { try await tools.approvalBinding(for: call("unknown", [:]), conversationId: "c") }
    }

    @Test func desktopReadOnlyBindingsRemainAvailableWithoutAX() async throws {
        let tools = AskLocalTools(registry: registry())
        tools.computerProbe.accessibilityTrusted = { false }
        let inspect = try call("computer", ["action": "inspect"])
        await #expect(throws: (any Error).self) { try await tools.approvalBinding(for: inspect, conversationId: "c") }
        let wait = try call("computer", ["action": "wait", "seconds": 0])
        let binding = try await tools.approvalBinding(for: wait, conversationId: "c")
        var checks = 0
        _ = try await tools.executeApproved(wait, conversationId: "c", binding: binding) { checks += 1 }
        #expect(checks >= 2)
        let screenshot = try call("computer", ["action": "screenshot"])
        if !NSScreen.screens.isEmpty {
            let display = try await tools.approvalBinding(for: screenshot, conversationId: "c")
            #expect(display.target.id.hasPrefix("display:")); #expect(!display.allowsReuse)
        }
    }

    @Test func nativeEvidenceFailsClosedForAnUnavailableProcess() {
        #expect(AskLocalTools.focusedWindow(-1) == nil)
        #expect(AskLocalTools.windowFrame(AXUIElementCreateApplication(-1)) == nil)
    }
}
