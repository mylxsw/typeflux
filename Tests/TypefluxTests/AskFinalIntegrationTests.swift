import Foundation
import Testing
@testable import Typeflux

/// Only the external completion is replaced; requests, queue, engine, journal and tools are real.
private actor IntegrationCompletion: AskModelCompleting {
    private var calls = 0
    private var entered: Set<Int> = []
    private var observers: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    let path: String
    init(path: String) {
        self.path = path
    }

    func untilEntered(_ call: Int) async {
        if !entered.contains(call) {
            await withCheckedContinuation { observers[call] = $0 }
        }
    }

    func release(_ call: Int) {
        releases.removeValue(forKey: call)?.resume()
    }

    var count: Int {
        calls
    }

    func complete(provider _: RegisteredProvider, connection _: SettingsStore.TextLLMConfiguration,
                  payload _: String, onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                  onProgress _: (@Sendable (AskStreamProgress) async -> Void)?) async throws
        -> (String, [AskToolCall]) {
        calls += 1
        let ordinal = calls
        await onUsage?(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10))
        if ordinal <= 2 {
            await withCheckedContinuation { continuation in
                releases[ordinal] = continuation
                entered.insert(ordinal)
                observers.removeValue(forKey: ordinal)?.resume()
            }
        }
        if ordinal == 2 {
            let data = try JSONSerialization.data(withJSONObject: ["action": "read", "path": path])
            return (
                "",
                [.init(
                    id: "scoped-read",
                    function: .init(name: "files", arguments: String(decoding: data, as: UTF8.self))
                )]
            )
        }
        return ("Synthetic final answer", [])
    }
}

@Suite("Final application integration", .exclusiveUIState)
@MainActor
struct AskFinalIntegrationTests {
    private func operation(_ model: AskConversationModel, _ id: String) throws -> Task<Void, Never> {
        let tasks = Mirror(reflecting: model).children.first { $0.label == "operations" }?.value as? [String: Task<
            Void,
            Never
        >]
        return try #require(tasks?[id])
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(predicate(), "Application did not reach the expected observable state")
    }

    @Test(arguments: ["complete", "revoke", "stop", "reset", "remove"])
    func `queue engine and folder authority`(action: String) async throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        let name = "final-integration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            KeychainTokenStore.useInMemoryStoreForTesting = false
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("sentinel.txt")
        try Data("Only the authorized run may read this sentinel".utf8).write(to: file)
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let profile = AskModelProfile(name: "Synthetic", baseURL: "https://example.invalid/v1", model: "fixture")
        try library.save(profile, key: "synthetic-key")
        defer { KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id) }
        library.settings.askAutomaticTitles = false
        let engine = AskLocalEngine(directory: root.appendingPathComponent("state"), budgetEnabled: true)
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults)),
                                  settings: library.settings, owner: { AskRoutedAPI.localOwner })
        let completion = IntegrationCompletion(path: file.path)
        let model = try AskConversationModel(api: AskApplicationAPI.routed(cloud: AskTestAPI(), local: engine),
                                             cache: AskConversationCache(
                                                 url: root.appendingPathComponent("cache.sqlite")
                                             ),
                                             tools: tools,
                                             capture: AskTestCapture(), deviceId: "device", modelLibrary: library,
                                             defaults: defaults,
                                             session: { (AskRoutedAPI.localOwner, "") }, modelClient: completion)
        model.lastConversationKind = .work // Predates conversation kinds: keep tool flows.
        defer { model.resetSession() }
        model.automaticRecoveryEnabled = false
        do {
            model.launcherDraft.text = "First scoped request"
            model.launcherDraft.modelRef = profile.reference
            model.launcherDraft.includeScreenshot = false
            model.launcherDraft.attachments = [.init(kind: .folder, name: "Synthetic folder", path: root.path)]
            model.submitLauncher()
            await completion.untilEntered(1)
            let id = try #require(model.selectedId)
            let firstTask = try operation(model, id)
            let originalRun = try #require(model.selected?.run?.id)
            model.draft.text = "Queued scoped request"
            model.draft.modelRef = profile.reference
            model.draft.attachments = [.init(kind: .folder, name: "Synthetic folder", path: root.path)]
            model.submitDraft()
            let queued = try #require(model.queuedMessages.first)
            #expect(model.queuedMessages.count == 1)
            #expect(model.selected?.run?.id == originalRun)
            if action == "remove" {
                model.removeQueued(queued.id)
            }
            await completion.release(1)
            await firstTask.value
            if action == "remove" {
                #expect(await completion.count == 1)
                #expect(model.queuedMessages.isEmpty)
                #expect(try await engine.conversation(id: id, token: "").messages.filter { $0.role == "user" }
                    .count == 1)
                return
            }
            await completion.untilEntered(2)
            let queuedTask = try operation(model, id)
            let run = try #require(model.selected?.run?.id)
            #expect(run != originalRun)
            #expect(model.queuedMessages.isEmpty)
            let stored = try await engine.conversation(id: id, token: "")
            #expect(stored.messages.filter { $0.id == queued.id }.count == 1)
            #expect(!tools.fileTools(conversationId: id).roots.isEmpty)
            if action == "revoke" {
                model.revokeTemporaryFolder(nil)
            }
            if action == "stop" {
                model.stop(id: id)
            }
            if action == "reset" {
                model.resetSession()
            }
            await completion.release(2)
            if action == "complete" {
                try await until { model.pendingApprovals[id] != nil || model.busyIds.isEmpty }
                if model.pendingApprovals[id] != nil {
                    model.approve(conversationId: id, allowed: true)
                }
            }
            await queuedTask.value
            let final = try await engine.conversation(id: id, token: "")
            let results = final.messages.filter { $0.toolCallId == "scoped-read" }
            if action == "complete" {
                #expect(final.run?.status == "completed")
                #expect(results.count == 1)
                #expect(results.first?.text.contains("Only the authorized run") == true)
                #expect(results.first?.isError == false)
            } else {
                #expect(!results.contains { $0.text.contains("Only the authorized run") })
                if action == "stop" {
                    // Attached folders last for the conversation (f5191368): stop ends the run,
                    // but the conversation keeps its folder until it is revoked or the session ends.
                    #expect(!tools.fileTools(conversationId: id).roots.isEmpty)
                } else {
                    #expect(tools.fileTools(conversationId: id).roots.isEmpty)
                }
                if action == "reset" {
                    #expect(model.selected == nil)
                }
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == "Only the authorized run may read this sentinel")
            #expect(await completion.count <= 3)
        } catch {
            let tasks = Mirror(reflecting: model).children.first { $0.label == "operations" }?.value as? [String: Task<
                Void,
                Never
            >]
            model.resetSession()
            await completion.release(1)
            await completion.release(2)
            for task in tasks?.values ?? [String: Task<Void, Never>]().values {
                await task.value
            }
            throw error
        }
    }
}
