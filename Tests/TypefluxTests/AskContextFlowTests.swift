import Foundation
import Testing
@testable import Typeflux

/// External replies are deterministic; the launcher, tool approval, storage and prompt loop are real.
private actor ContextFlowCompletion: AskModelCompleting {
    let usesDirectory: Bool
    var payloads: [String] = []
    init(usesDirectory: Bool) { self.usesDirectory = usesDirectory }

    func complete(provider _: RegisteredProvider, connection _: SettingsStore.TextLLMConfiguration,
                  payload: String, onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                  onProgress _: (@Sendable (AskStreamProgress) async -> Void)?) async throws -> (String, [AskToolCall]) {
        payloads.append(payload)
        let index = payloads.count
        await onUsage?(.init(promptTokens: 100 * index, completionTokens: 20, totalTokens: 100 * index + 20))
        if usesDirectory && index == 1 {
            return ("", [.init(id: "find", function: .init(name: AskMCPDiscovery.name, arguments: #"{"query":"list projects"}"#))])
        }
        if index == 2 {
            let name = usesDirectory ? "mcp_workspace_projects" : "notebook"
            let arguments = usesDirectory ? "{}" : #"{"action":"create","body":"A greeting lesson"}"#
            return ("", [.init(id: "execute", function: .init(name: name, arguments: arguments))])
        }
        return (usesDirectory ? "Atlas" : "A greeting lesson", [])
    }
}

@Suite("Agent context end to end", .exclusiveUIState)
@MainActor struct AskContextFlowTests {
    private func names(_ payload: String) throws -> [String] {
        let body = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        return (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    private func finish(_ model: AskConversationModel) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        repeat {
            if let id = model.selectedId, model.pendingApprovals[id] != nil { model.approve(conversationId: id, allowed: true) }
            if model.selected?.run?.status == "completed" && model.busyIds.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        try #require(Bool(false), "Expected completed conversation, got \(model.selected?.run?.status ?? "missing") / \(model.error ?? "no error")")
    }

    @Test func explicitImageAndDirectoryPaging() {
        var draft = AskDraft(text: "previous", screenshot: "ambient", selection: "old selection")
        draft.attachments = [.init(kind: .image, name: "illustration", image: "deliberate")]
        let request = draft.askingAboutWord("word").request(deviceId: "fixture", tools: [])
        #expect(request.answerOnly == true && request.image == nil && request.selection == nil)
        #expect(request.attachments?.map(\.image) == ["deliberate"])
        let catalog = (0..<10).map { AskToolDefinition(name: "mcp_read_\($0)", description: "Read", parameters: AskTypedContent.json([:]), mcpServer: "Example. Service") }
        let first = AskMCPDiscovery.search("{}", catalog: catalog)
        let next = AskMCPDiscovery.search(#"{"server":"Example. Service","offset":4}"#, catalog: catalog)
        #expect(first.names.count == 4 && next.names.count == 4 && Set(first.names).isDisjoint(with: next.names))
        #expect(AskMCPDiscovery.search(#"{"query":"不存在"}"#, catalog: catalog).names.isEmpty)
    }

    @Test(arguments: [false, true])
    func launcherThroughFinalAnswerAndRestart(usesDirectory: Bool) async throws {
        let domain = "context-flow-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        defer {
            KeychainTokenStore.useInMemoryStoreForTesting = previousStore
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let profile = AskModelProfile(name: "Context fixture", baseURL: "https://example.invalid", model: "fixture")
        try library.save(profile, key: "synthetic")
        defer { KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id) }
        library.settings.askAutomaticTitles = false
        let client = MockMCPClient()
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults), clientFactory: { _ in client })
        if usesDirectory {
            let schema = MCPObjectSchema(type: "object", properties: nil, required: nil, description: nil, additionalProperties: nil)
            let catalog = (0..<70).map { MCPToolDefinition(name: "action_\($0)", description: "Other capability", inputSchema: schema) }
            await client.setMockTools(catalog + [.init(name: "workspace_projects", description: "List projects", inputSchema: schema)])
            let result = #"{"project":"Atlas"}"#
            await client.setMockCallResult(.init(content: [.init(type: "text", text: result)], isError: false,
                                                 structuredContent: JSONValue(data: Data(result.utf8))))
            try await registry.addServer(.init(name: "Sample service", transport: .http(.init(url: "https://example.invalid"))))
        }
        let tools = AskLocalTools(registry: registry, settings: library.settings, owner: { AskRoutedAPI.localOwner })
        let notes = SQLiteAskNoteStore(url: root.appendingPathComponent("notes.sqlite"))
        notes.notificationCenter = NotificationCenter()
        tools.notebook = notes
        let state = root.appendingPathComponent("state")
        let engine = AskLocalEngine(directory: state)
        let completion = ContextFlowCompletion(usesDirectory: usesDirectory)
        let model = try AskConversationModel(api: AskApplicationAPI.routed(cloud: AskTestAPI(), local: engine),
            cache: AskConversationCache(url: root.appendingPathComponent("cache.sqlite")), tools: tools,
            capture: AskTestCapture(), deviceId: "device", modelLibrary: library, defaults: defaults,
            session: { (AskRoutedAPI.localOwner, "") }, modelClient: completion)
        defer { model.resetSession() }
        model.automaticRecoveryEnabled = false
        model.lastConversationKind = .work
        model.launcherDraft = .init(text: usesDirectory ? "有哪些项目？" : "hello", includeScreenshot: false, modelRef: profile.reference, kind: "work")
        if usesDirectory {
            model.submitLauncher()
        } else {
            model.launcherDraft.includeScreenshot = true
            model.launcherDraft.screenshot = "unrelated-screen"
            model.launcherDraft.selection = "unrelated-selection"
            _ = model.performPluginAction(.init(wordCardQuestion: true, kind: .askAI("解释 hello 的用法"), title: "Ask", symbol: "bubble.left"))
        }
        try await finish(model)
        let id = try #require(model.selectedId)
        if !usesDirectory {
            #expect(model.usageContext?.estimated == false && model.usageContext?.inputTokens == 100)
            model.draft.text = "把刚才的解释存成笔记"
            #expect(model.submitDraft())
            try await finish(model)
            let saved = try await AskNotebookTool(store: notes, hiddenTags: []).searchNotes("greeting", limit: 10)
            #expect(saved.count == 1 && saved.first?.note.body == "A greeting lesson")
        }
        let prompts = await completion.payloads
        try #require(prompts.count == 3)
        if usesDirectory {
            #expect(try names(prompts[0]).contains(AskMCPDiscovery.name))
            #expect(try !names(prompts[0]).contains(where: { $0.hasPrefix("mcp_") }))
            #expect(try names(prompts[1]).contains("mcp_workspace_projects"))
            #expect(await client.callToolCallCount == 1)
            #expect(!prompts[2].contains("Structured content:"))
            #expect(model.selected?.messages.last(where: { $0.role == "tool" })?.harness?.outcome?.content?.count == 2)
        } else {
            #expect(try names(prompts[0]).isEmpty)
            #expect(!prompts[0].contains("unrelated-"))
            #expect(try names(prompts[1]).contains("notebook"))
        }
        let restored = try await AskLocalEngine(directory: state).conversation(id: id, token: "")
        #expect(restored.run?.status == "completed" && restored.contextUsage?.estimated == false)
        #expect(restored.contextUsage?.inputTokens == 300 && restored.usage?.total.inputTokens == 600)
    }
}
