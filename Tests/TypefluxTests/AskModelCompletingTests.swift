import Foundation
import Testing
@testable import Typeflux

/// Never opens a socket. Holding ignores cancellation so host guards see late callbacks.
actor RecordingAskModelClient: AskModelCompleting {
    struct Invocation: Sendable {
        let provider: RegisteredProvider
        let connection: SettingsStore.TextLLMConfiguration
        let payload: String
        let hasUsage: Bool
        let hasProgress: Bool
    }

    var invocations: [Invocation] = []
    var held = false
    var failure = false
    var toolCalls: [AskToolCall] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() {
        held = true
    }

    func fail() {
        failure = true
    }

    func setTools(_ calls: [AskToolCall]) {
        toolCalls = calls
    }

    func release() {
        held = false; waiter?.resume(); waiter = nil
    }

    func complete(provider: RegisteredProvider, connection: SettingsStore.TextLLMConfiguration,
                  payload: String, onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                  onProgress: (@Sendable (AskStreamProgress) async -> Void)?) async throws -> (String, [AskToolCall]) {
        invocations.append(.init(provider: provider, connection: connection, payload: payload,
                                 hasUsage: onUsage != nil, hasProgress: onProgress != nil))
        if held {
            await withCheckedContinuation { waiter = $0 }
        }
        await onUsage?(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10))
        await onProgress?(.init(text: "Synthetic answer", reasoning: "Synthetic reasoning", truncated: true))
        if failure {
            throw AskStreamError.requestFailed
        }
        return ("Synthetic answer", toolCalls)
    }
}

@Suite("Host model completion port", .exclusiveUIState)
@MainActor struct AskModelCompletingTests {
    private func environment(_ body: (UserDefaults, AskModelLibrary, AskModelProfile, URL) async throws
        -> Void) async throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        let name = "model-port-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            KeychainTokenStore.useInMemoryStoreForTesting = false
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let profile = AskModelProfile(
            name: "Synthetic",
            baseURL: "https://example.invalid/v1",
            model: "synthetic-upstream"
        )
        try library.save(profile, key: "synthetic-port-key")
        defer { KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id) }
        library.settings.askAutomaticTitles = false
        try await body(defaults, library, profile, root)
    }

    private func pending(_ reference: String, summary: Bool = false) -> AskConversation {
        var value = AskConversation(id: UUID().uuidString.lowercased(), title: "Question", revision: 1,
                                    updatedAt: Date(), messages: [.init(
                                        id: "question",
                                        role: "user",
                                        text: "Question",
                                        createdAt: Date()
                                    )])
        value.modelRef = reference
        value.run = .init(id: "run", deviceId: "device", status: "waiting_inference", steps: 1,
                          updatedAt: Date(), tools: [], pending: [])
        value.run?.modelRef = reference
        value.run?.inference = .init(id: "inference", payload: AskLocalPrompt.json([
            "model": reference, "messages": [["role": "user", "content": "Prepared question"]]
        ]), summaryThrough: summary ? 1 : nil)
        return value
    }

    private func model(_ api: any AskAPI, cache: any AskCaching, defaults: UserDefaults,
                       library: AskModelLibrary, fake: any AskModelCompleting,
                       state: AskTestSession) -> AskConversationModel {
        let host = AskConversationModel(api: api, cache: cache, tools: AskTestTools(), capture: AskTestCapture(),
                                        deviceId: "device", modelLibrary: library, defaults: defaults,
                                        session: { state.token.isEmpty ? nil : (state.owner, state.token) }, modelClient: fake)
        host.lastConversationKind = .work // Predates conversation kinds: keep tool flows.
        return host
    }

    /// Collect host-owned tasks without widening the production visibility boundary.
    private func operation(_ host: AskConversationModel, id: String) -> Task<Void, Never>? {
        let tasks = Mirror(reflecting: host).children.first { $0.label == "operations" }?.value
            as? [String: Task<Void, Never>]
        return tasks?[id]
    }

    @Test func `conversation and foreground summary preserve prepared input callbacks and receipt replay`(
    ) async throws {
        try await environment { defaults, library, profile, root in
            for summary in [false, true] {
                let api = AskTestAPI(), fake = RecordingAskModelClient(), state = AskTestSession()
                let cache = try AskConversationCache(url: root.appendingPathComponent(UUID().uuidString + ".sqlite"))
                let host = model(api, cache: cache, defaults: defaults, library: library, fake: fake, state: state)
                defer { host.resetSession() }
                let value = pending(profile.reference, summary: summary)
                await api.seed(value)
                await host.select(value.id)
                host.resume()
                let task = try #require(operation(host, id: value.id))
                await task.value
                let call = try #require(await fake.invocations.first)
                #expect(call.provider.id == "endpoint:" + profile.id)
                #expect(call.connection.model == "synthetic-upstream")
                #expect(call.connection.apiKey == "synthetic-port-key")
                #expect(call.payload.contains("Prepared question"))
                #expect(call.hasUsage && call.hasProgress)
                let receipt = try #require(await api.inferenceResults.first)
                #expect(receipt.content == "Synthetic answer")
                #expect(receipt.usage?.totalTokens == 10)
                #expect(receipt.finishReason == (summary ? nil : "length"))
                // Acknowledged persisted receipts must not reopen transport on snapshot replay.
                await api.seed(value)
                var replay = value; replay.revision = 20
                await api.seed(replay)
                await host.select(value.id, reload: true)
                host.resume()
                if let task = operation(host, id: value.id) {
                    await task.value
                }
                #expect(await fake.invocations.count == 1)
                #expect(await api.inferenceResults.count == 1)
            }
        }
    }

    @Test func `binding ownership and missing model never reach transport`() async throws {
        try await environment { defaults, library, profile, root in
            for mode in ["binding", "device", "missing", "unauthorized", "selection"] {
                let api = AskTestAPI(), fake = RecordingAskModelClient(), state = AskTestSession()
                let cache = try AskConversationCache(url: root.appendingPathComponent(mode + ".sqlite"))
                let host = model(api, cache: cache, defaults: defaults, library: library, fake: fake, state: state)
                defer { host.resetSession() }
                var value = pending(mode == "missing" ? "custom:absent" : profile.reference)
                if mode == "binding" {
                    value.run?.agentBinding = .init(id: "future.runtime", version: 1)
                }
                if mode == "device" {
                    value.run?.deviceId = "other-device"
                }
                let registry = library.registry
                defer { try? library.commit(registry) }
                if mode == "selection",
                   let index = library.registry.providers.firstIndex(where: { $0.id == "endpoint:" + profile.id }) {
                    var restricted = registry
                    restricted.providers[index].models[0].scenarios = ["rewrite"]
                    try library.commit(restricted)
                }
                await api.seed(value)
                await host.select(value.id)
                if mode == "unauthorized" {
                    state.token = ""
                }
                host.resume()
                if let task = operation(host, id: value.id) {
                    await task.value
                }
                #expect(await fake.invocations.isEmpty)
            }
        }
    }

    @Test func `held completion cannot publish after cancellation replacement or account change`() async throws {
        try await environment { defaults, library, profile, root in
            for mode in ["cancel", "replacement", "account"] {
                let api = AskTestAPI(), fake = RecordingAskModelClient(), state = AskTestSession()
                await fake.hold()
                let cache = try AskConversationCache(url: root.appendingPathComponent(mode + ".sqlite"))
                let host = model(api, cache: cache, defaults: defaults, library: library, fake: fake, state: state)
                defer { host.resetSession() }
                let value = pending(profile.reference)
                await api.seed(value)
                await host.select(value.id)
                host.resume()
                let task = try #require(operation(host, id: value.id))
                for _ in 0 ..< 500 {
                    if await !fake.invocations.isEmpty {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                #expect(await fake.invocations.count == 1)
                task.cancel()
                if mode == "account" {
                    state.owner = "new-account"; host.resetSession()
                }
                if mode != "account" {
                    var newer = value; newer.revision = 99
                    if mode == "cancel" {
                        newer.run?.status = "cancelled"; newer.run?.inference = nil
                    }
                    newer.run?.id = "replacement-run"
                    newer.run?.inference?.id = "replacement-inference"
                    await api.seed(newer)
                    let route = try #require(host.credentials(for: value.id))
                    try await host.accept(newer, route: route)
                }
                await fake.release()
                await task.value
                #expect(await api.inferenceResults.isEmpty)
                #expect(host.inferenceProgress[value.id]?.text != "Synthetic answer")
            }
        }
    }

    @Test func `auxiliary and factory summary capture injected instance and failed receipts`() async throws {
        try await environment { defaults, library, profile, _ in
            let fake = RecordingAskModelClient()
            let api = AskConversationWindowController.makeAPI(settings: SettingsStore(defaults: defaults),
                                                              modelLibrary: library, cloud: AskTestAPI(),
                                                              modelClient: fake)
            let routed = try #require(api.runtime as? AskRoutedAPI)
            let local = try #require(routed.local as? AskApplicationAPI)
            #expect(local.runtime is AskLocalEngine)
            let summary = AskConversationWindowController.makeSummary(modelLibrary: library, modelClient: fake)
            let inference = try #require(pending(profile.reference, summary: true).run?.inference)
            let receipt = await summary(inference, "run", "device")
            #expect(receipt.content == "Synthetic answer")
            #expect(receipt.usage?.totalTokens == 10)
            #expect(receipt.finishReason == "length")
            #expect(await fake.invocations.count == 1)
            await fake.fail()
            let failed = await AskAuxiliaryInference.complete(
                inference,
                run: "run",
                device: "device",
                library: library,
                client: fake
            )
            #expect(failed.failed && failed.content.isEmpty)
            #expect(failed.usage?.totalTokens == 10)
            #expect(await fake.invocations.count == 2)
            let missing = AskInference(id: "missing", payload: "{}")
            #expect(await AskAuxiliaryInference.complete(
                missing,
                run: "run",
                device: "device",
                library: library,
                client: fake
            ).failed)
            #expect(await fake.invocations.count == 2)
        }
    }

    @Test func `background engine uses factory summary closure and collects held task`() async throws {
        try await environment { _, library, profile, root in
            let fake = RecordingAskModelClient()
            await fake.hold()
            let summary = AskConversationWindowController.makeSummary(modelLibrary: library, modelClient: fake)
            // Reuse the production factory closure in isolated storage, never the user's local store.
            var original = pending(profile.reference)
            original.run = nil
            original.messages = (0 ..< 32).map { index in
                .init(id: "history-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                      text: "Synthetic history \(index)", createdAt: Date())
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try AskCoding.encoder().encode(AskLocalRecord(conversation: original))
                .write(to: root.appendingPathComponent(original.id + ".json"))
            let engine = AskLocalEngine(directory: root, summarize: summary)
            let sent = try await engine.send(conversationId: original.id, request: .init(
                id: "next",
                deviceId: "device",
                text: "Continue",
                tools: [],
                modelRef: profile.reference
            ), token: "")
            for _ in 0 ..< 500 {
                if await !fake.invocations.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(await fake.invocations.count == 1)
            #expect(sent.run?.inference?.summaryThrough == nil)
            // The actor is suspended in the held fake; capture its task before releasing it.
            let preparations = Mirror(reflecting: engine).children.first { $0.label == "summaries" }?.value
            let entry = preparations.flatMap { Mirror(reflecting: $0).children.first?.value }
            let preparation = entry.flatMap { Mirror(reflecting: $0).children.first { $0.label == "value" }?.value }
            let captured = preparation.flatMap { Mirror(reflecting: $0).children.first { $0.label == "task" }?.value }
                as? Task<AskInferenceResult, Never>
            await fake.release()
            let task = try #require(captured)
            let receipt = await task.value
            #expect(receipt.usage?.totalTokens == 10)
            let call = try #require(await fake.invocations.first)
            #expect(call.payload.contains("Synthetic history"))
            #expect(call.connection.model == "synthetic-upstream")
            let usage = try await engine.usage(id: original.id, runId: nil, cursor: nil, token: "")
            #expect(usage.items.contains { $0.purpose == "summary" })
        }
    }

    @Test func `workflow cancellation rejects held progress and late reply`() async throws {
        try await environment { defaults, library, _, root in
            let engine = AskLocalEngine(directory: root), fake = RecordingAskModelClient()
            await fake.hold()
            let assistant = AskWorkflowAssistant(dependencies: .init(api: engine, session: { ("owner", "") },
                                                                     deviceId: "device", modelLibrary: library,
                                                                     inference: fake, defaults: defaults))
            assistant.send("Synthetic held workflow")
            for _ in 0 ..< 500 {
                if await !fake.invocations.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            let captured = Mirror(reflecting: assistant).children.first { $0.label == "task" }?.value
                as? Task<Void, Never>
            captured?.cancel()
            await fake.release()
            let task = try #require(captured)
            await task.value
            #expect(assistant.preview.isEmpty)
            let id = try #require(assistant.conversationID)
            let final = try await engine.conversation(id: id, token: "")
            #expect(final.messages.last?.role == "user")
            #expect(final.run?.status == "waiting_inference")
        }
    }

    @Test func `workflow uses injected client without changing usage semantics`() async throws {
        try await environment { defaults, library, _, root in
            let engine = AskLocalEngine(directory: root), fake = RecordingAskModelClient()
            let defaultDependencies = AskWorkflowAssistant.Dependencies(api: engine, session: { ("owner", "") },
                                                                        deviceId: "device", modelLibrary: library)
            #expect(defaultDependencies.inference is AskDeviceModelClient)
            let cache = try AskConversationCache(url: root.appendingPathComponent("default.sqlite"))
            let defaultHost = AskConversationModel(
                api: engine,
                cache: cache,
                tools: AskTestTools(),
                capture: AskTestCapture(),
                deviceId: "device",
                modelLibrary: library,
                defaults: defaults,
                session: { ("owner", "") }
            )
            defaultHost.lastConversationKind = .work // Predates conversation kinds: keep tool flows.
            #expect(defaultHost.customInference is AskCustomInference)
            defaultHost.resetSession()
            let assistant = AskWorkflowAssistant(dependencies: .init(
                api: engine,
                session: { ("owner", "") },
                deviceId: "device",
                modelLibrary: library,
                inference: fake,
                defaults: defaults
            ))
            assistant.send("Create a synthetic workflow")
            for _ in 0 ..< 1000 {
                if !assistant.isBusy {
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(!assistant.isBusy)
            let invocation = try #require(await fake.invocations.first)
            #expect(!invocation.hasUsage && invocation.hasProgress)
            #expect(invocation.payload.contains("Create a synthetic workflow"))
            #expect(invocation.connection.model == "synthetic-upstream")
            let id = try #require(assistant.conversationID)
            let final = try await engine.conversation(id: id, token: "")
            #expect(final.run?.status == "completed")
            #expect(final.messages.last?.text == "Synthetic answer")
        }
    }
}
