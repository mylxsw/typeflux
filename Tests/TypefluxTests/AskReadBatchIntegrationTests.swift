import Foundation
import Testing
@testable import Typeflux

private actor ReadBatchCompletion: AskModelCompleting {
    let tools: [AskToolCall]
    var count = 0
    init(_ tools: [AskToolCall]) { self.tools = tools }
    func complete(provider _: RegisteredProvider, connection _: SettingsStore.TextLLMConfiguration,
                  payload _: String, onUsage _: (@Sendable (AskTokenUsage) async -> Void)?,
                  onProgress _: (@Sendable (AskStreamProgress) async -> Void)?) async throws -> (String, [AskToolCall]) {
        count += 1
        return count == 1 ? ("", tools) : ("Finished", [])
    }
}

private actor ReadBatchMCPClient: MCPClient {
    let gate: ReadBatchGate
    var isConnected = false
    var serverInfo: MCPConnectionInfo? { nil }
    init(_ gate: ReadBatchGate) { self.gate = gate }
    func connect() { isConnected = true }
    func disconnect() { isConnected = false }
    func ping() {}
    func listTools() -> [MCPToolDefinition] {
        [.init(name: "lookup", description: "Lookup", inputSchema: .init(type: "object", properties: nil,
            required: nil, description: nil, additionalProperties: nil), annotations: .init(readOnlyHint: true, destructiveHint: false))]
    }
    func callTool(name _: String, arguments: [String: Any]) async throws -> MCPToolsCallResult {
        let id = arguments["id"] as? String ?? "missing"
        await gate.enter(id)
        return .init(content: [.init(type: "text", text: id)], isError: false)
    }
}

private final class ReadBatchFileGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = 0
    private var released = false
    var count: Int { condition.withLock { entered } }
    func enter() {
        condition.lock(); defer { condition.unlock() }
        entered += 1
        let deadline = Date().addingTimeInterval(10)
        while !released && condition.wait(until: deadline) {}
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
}

@Suite("Chat read batch integration", .exclusiveUIState)
@MainActor struct AskReadBatchIntegrationTests {
    private func until(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await condition())
    }

    @Test(arguments: ["web", "files", "mcp", "strict", "deny", "cancel", "revoke"])
    func normalChatChecksEveryCallAndShowsRealProgress(kind: String) async throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        let name = "read-batch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            KeychainTokenStore.useInMemoryStoreForTesting = false
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let profile = AskModelProfile(name: "Synthetic", baseURL: "https://example.invalid/v1", model: "fixture")
        try library.save(profile, key: "synthetic")
        defer { KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id) }
        library.settings.askAutomaticTitles = false
        library.settings.askFileAccessFolders = [root.path]
        let gate = ReadBatchGate(), fileGate = ReadBatchFileGate()
        defer { Task { for index in 0..<3 { await gate.release("call\(index)") } } }
        defer { fileGate.release() }
        let client = ReadBatchMCPClient(gate)
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults), clientFactory: { _ in client })
        let server = MCPServerConfig(name: "Synthetic", transport: .http(.init(url: "https://example.invalid/mcp")))
        if kind == "mcp" { try await registry.addServer(server) }
        let tools = AskLocalTools(registry: registry, settings: library.settings, owner: { AskRoutedAPI.localOwner })
        if kind == "files" { tools.fileOperationHooks.onEvent = { if $0 == "read" { fileGate.enter() } } }
        _ = await tools.definitions(conversationId: nil)
        if kind == "mcp" {
            let entry = try #require(library.settings.toolPermissionEntries.first { $0.tool == "mcp_lookup" })
            library.settings.setToolPermission(.allow, entry: entry, mode: .standard)
        }
        var calls: [AskToolCall] = []
        for index in 0..<3 {
            let id = "call\(index)"
            let tool: String, arguments: String
            if kind == "files" {
                let file = root.appendingPathComponent("\(index).txt")
                try Data(id.utf8).write(to: file)
                tool = "files"
                arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "read", "path": file.path]), as: UTF8.self)
            } else if kind == "mcp" { tool = "mcp_lookup"; arguments = "{\"id\":\"\(id)\"}" }
            else { tool = index == 1 && kind == "deny" ? "web_fetch" : "web_search"; arguments = "{}" }
            calls.append(.init(id: id, function: .init(name: tool, arguments: arguments)))
        }
        if kind == "deny" {
            library.settings.setToolPermission(.deny, entry: AskToolAuthorization.entry(for: calls[1]), mode: .standard)
        }
        let engine = AskLocalEngine(directory: root.appendingPathComponent("state"), budgetEnabled: true, builtinTools: ReadBatchHost(gate: gate))
        let completion = ReadBatchCompletion(calls)
        let cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        let model = AskConversationModel(api: AskApplicationAPI.routed(cloud: AskTestAPI(), local: engine),
            cache: cache, tools: tools, capture: AskTestCapture(), deviceId: "device", modelLibrary: library,
            defaults: defaults, session: { (AskRoutedAPI.localOwner, "") }, modelClient: completion)
        defer {
            print("READ_BATCH \(kind) status=\(model.selected?.run?.status ?? "none") error=\(model.error ?? "none") pending=\(model.selected?.run?.pending.map(\.id) ?? [])")
            model.resetSession()
        }
        model.automaticRecoveryEnabled = false
        model.lastConversationKind = .work
        if kind == "strict" { model.setPermissionMode(.strict, launcher: true) }
        model.launcherDraft.kind = AskConversationKind.work.rawValue
        model.launcherDraft.text = "Read three independent sources"
        model.launcherDraft.modelRef = profile.reference
        model.launcherDraft.includeScreenshot = false
        model.submitLauncher()
        try await until { model.selectedId != nil }
        let id = try #require(model.selectedId)
        if kind == "strict" {
            try await until { model.pendingApprovals[id] != nil }
            #expect(await gate.entered.isEmpty)
            #expect(model.readBatchProgress[id] == nil)
            model.stop(id: id)
            return
        }
        if kind == "deny" {
            await gate.release("call0"); await gate.release("call2")
            try await until { model.selected?.run?.status == "completed" }
            #expect(await gate.entered == ["call0", "call2"])
            #expect(model.selected?.messages.first { $0.toolCallId == "call1" }?.isError == true)
            return
        }
        if kind == "files" { try await until { fileGate.count == 3 || model.error != nil } }
        else { try await until { await gate.entered.count == 3 || model.error != nil } }
        try #require(model.error == nil)
        #expect(model.readBatchProgress[id]?.running.count == 3)
        if kind == "cancel" { model.stop(id: id) }
        if kind == "revoke" { model.setPermissionMode(.strict, launcher: false) }
        if kind == "files" { fileGate.release() }
        else {
            await gate.release("call2")
            if kind != "cancel" {
                try await until { model.readBatchProgress[id]?.completed.count == 1 }
                #expect(model.readBatchProgress[id]?.running.count == 2)
                #expect(model.readBatchProgress[id]?.completed.first?.toolCallId == "call2")
                #expect(await completion.count == 1)
            }
            await gate.release("call1"); await gate.release("call0")
        }
        try await until { model.readBatchProgress[id] == nil }
        if kind == "cancel" {
            #expect(try await engine.conversation(id: id, token: "").run?.status == "cancelled")
        } else {
            try await until { model.selected?.run?.status == "completed" }
            let value = try await engine.conversation(id: id, token: "")
            #expect(value.messages.filter { $0.role == "tool" }.compactMap(\.toolCallId) == calls.map(\.id))
            #expect(await completion.count == 2)
            let grants = value.messages.filter { $0.role == "tool" }.compactMap { $0.harness?.approval?.id }
            #expect(Set(grants).count == 3)
            #expect(value.messages.filter { $0.role == "tool" }.allSatisfy { $0.harness?.approval?.consumedAt != nil })
        }
        if kind == "mcp" { await registry.removeServer(id: server.id) }
    }
}
