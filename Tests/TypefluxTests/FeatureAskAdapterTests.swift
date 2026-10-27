import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureAskAdapterTests {
    @Test func reconnectBootstrapWaitsForBusyHostToDrain() async throws {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let client = try FeatureRPC(descriptor: sockets[0]), server = try FeatureRPC(descriptor: sockets[1])
        let snapshot = FeatureAuth(generation: 7, token: nil, expiresAt: nil, profile: nil,
            subscription: .init(planCode: nil, status: nil, currentPeriodStart: nil, currentPeriodEnd: nil,
                                cancelAtPeriodEnd: false, entitled: false))
        let state = BootstrapRetryFixture(snapshot: snapshot)
        await client.start { _, data in data }
        await server.start { _, _ in try await state.reply() }
        let result = try await FeatureAuth.bootstrapAfterReconnect(client, initialDelay: .milliseconds(5), maximumDelay: .milliseconds(10))
        #expect(result.generation == 7)
        #expect(await state.calls == 3)
        await client.stop(); await server.stop()
    }

    @Test func reconnectRetriesReadsButDoesNotReplayDraftWrites() async throws {
        let listener = try FeatureReconnectListener(), state = CacheDisconnectFixture()
        defer { listener.stop() }
        listener.setExpectedPeerPID(getpid())
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let client = try FeatureRPC(descriptor: sockets[0], reconnect: {
            try await FeatureReconnectListener.connect(path: listener.path, secret: listener.secret, expectedPeerPID: getpid())
        })
        let server = try FeatureRPC(descriptor: sockets[1], reconnect: { try await listener.acceptConnection() })
        let storage = try AskConversationCache.inMemory()
        try await storage.saveDraft(AskDraft(text: "Original"), key: "fixture", owner: "owner")
        await client.start { _, data in data }
        await server.start { method, payload in
            let call = try JSONDecoder().decode(FeatureAskCall.self, from: payload)
            let result = try await FeatureAskCache.handle(method, payload: call.payload, api: storage)
            if await state.shouldDisconnect(method) { await server.simulateDisconnect() }
            return result
        }
        let cache = FeatureAskCache(connection: client, generation: { 0 })
        #expect(try await cache.draft(key: "fixture", owner: "owner")?.text == "Original")
        #expect(await state.count("cache.draft.11") == 2)
        await #expect(throws: FeatureRPC.Failure.unavailable) {
            try await cache.saveDraft(AskDraft(text: "New"), key: "fixture", owner: "owner")
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await state.count("cache.saveDraft.10") == 1)
        #expect(try await cache.draft(key: "fixture", owner: "owner")?.text == "New")
        await client.stop(); await server.stop()
    }

    @Test func staleCacheReadRefreshesAuthOnceButNeverReplaysAWrite() async throws {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let client = try FeatureRPC(descriptor: sockets[0]), server = try FeatureRPC(descriptor: sockets[1])
        let state = CacheAuthRetryFixture()
        await client.start { _, data in data }
        await server.start { try await state.handle($0, payload: $1) }
        let cache = FeatureAskCache(connection: client, generation: { await state.generation },
            synchronizeAuth: { _, owner in await state.refresh(owner: owner) })
        #expect(try await cache.draft(key: "fixture", owner: "owner")?.text == "Unsent")
        #expect(await state.refreshes == 1)
        await state.makeStale()
        await #expect(throws: AuthError.self) {
            try await cache.saveDraft(.followUp, key: "fixture", owner: "owner")
        }
        #expect(await state.refreshes == 1)
        #expect(await state.writes == 0)
        await client.stop(); await server.stop()
    }

    @Test func cacheAuthRefreshCannotSwitchAccountsOrApplyAnOlderGeneration() {
        let profile = UserProfile(id: "owner", email: "fixture@example.com", name: "Fixture", status: 1,
            provider: "email", createdAt: "", updatedAt: "")
        let snapshot = FeatureAuth(generation: 2, token: "fixture-token", expiresAt: nil, profile: profile,
            subscription: .init(planCode: "free", status: "free", currentPeriodStart: nil, currentPeriodEnd: nil,
                cancelAtPeriodEnd: false, entitled: true))
        #expect(snapshot.permitsCacheReadRefresh(owner: "owner", currentOwner: "owner", generation: 1))
        #expect(snapshot.permitsCacheReadRefresh(owner: "local", currentOwner: "owner", generation: 2))
        #expect(!snapshot.permitsCacheReadRefresh(owner: "owner", currentOwner: "other", generation: 1))
        #expect(!snapshot.permitsCacheReadRefresh(owner: "other", currentOwner: "owner", generation: 1))
        #expect(!snapshot.permitsCacheReadRefresh(owner: "owner", currentOwner: "owner", generation: 3))
        #expect(!snapshot.permitsCacheReadRefresh(owner: "owner", currentOwner: nil, generation: 1))
    }

    private func pair(api: AskTestAPI, cache: any AskCaching,
                      allowedOwners: Set<String>? = nil) async throws -> (FeatureRPC, FeatureRPC) {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let client = try FeatureRPC(descriptor: sockets[0]), server = try FeatureRPC(descriptor: sockets[1])
        await client.start { _, _ in throw FeatureRPC.Failure.invalidMessage }
        await server.start { method, payload in
            let call = try JSONDecoder().decode(FeatureAskCall.self, from: payload)
            if method.hasPrefix("cache."), let allowedOwners {
                let identity = try JSONDecoder().decode(CacheOwner.self, from: call.payload)
                guard allowedOwners.contains(identity.owner) else {
                    return try JSONEncoder().encode(FeatureAskReply(payload: nil, error: .init(AuthError.unauthorized)))
                }
            }
            if method.hasPrefix("cache.") { return try await FeatureAskCache.handle(method, payload: call.payload, api: cache) }
            return try await FeatureAskAPI.handle(method, payload: call.payload, api: api)
        }
        return (client, server)
    }

    private struct CacheOwner: Decodable { let owner: String }

    @Test(arguments: [false, true])
    func coldChatDraftSaveInitializesOwnerBeforeCrossingTheHostBoundary(signedIn: Bool) async throws {
        let storage = try AskConversationCache.inMemory()
        let (client, server) = try await pair(api: AskTestAPI(), cache: storage, allowedOwners: ["local", "owner"])
        let cache = FeatureAskCache(connection: client, generation: { 0 })
        let fixture = try AskTestFixture(localOnly: !signedIn, cacheOverride: cache)
        defer { fixture.model.resetSession() }
        #expect(fixture.model.owner.isEmpty)
        // Confirm this fixture enforces the production host's owner boundary.
        await #expect(throws: (any Error).self) { try await cache.saveDraft(.followUp, key: "launcher", owner: "") }
        await fixture.model.flushFeatureDrafts()
        let account = signedIn ? "owner" : "local"
        #expect(fixture.model.owner == account)
        #expect(fixture.model.error == nil)
        #expect(try await storage.draft(key: "launcher", owner: account) != nil)
        #expect(try await storage.draft(key: "launcher", owner: "") == nil)
        await client.stop(); await server.stop()
    }

    @Test func productionChatOperationsRoundTripThroughTheTypedChannel() async throws {
        let backend = AskTestAPI(), cache = try AskConversationCache.inMemory()
        let (client, server) = try await pair(api: backend, cache: cache)
        let api = FeatureAskAPI(connection: client, generation: { 0 })
        let message = AskSendRequest(id: "message", deviceId: "device", text: "Question", selection: "Selected", source: "Editor", image: nil,
            tools: [], modelRef: "cloud:default", attachments: [.init(kind: .file, name: "notes.txt", text: "Notes")])
        let value = try await api.send(conversationId: "chat", request: message, token: "fixture-token")
        #expect(value.messages.first?.text == message.text)
        #expect(await backend.sends == [message])
        #expect(try await api.conversation(id: "chat", token: "fixture-token").id == "chat")
        #expect(try await api.list(token: "fixture-token", offset: 0).count == 1)
        let run = try #require(value.run)
        let tool = AskToolResultRequest(runId: run.id, deviceId: "device", toolCallId: "tool", content: "Result", isError: false)
        _ = try await api.result(conversationId: "chat", request: tool, token: "fixture-token")
        #expect(await backend.results.last == tool)
        let inference = AskInferenceResult(runId: run.id, deviceId: "device", inferenceId: "inference", content: "Answer")
        _ = try await api.inferenceResult(conversationId: "chat", request: inference, token: "fixture-token")
        #expect(await backend.inferenceResults.last == inference)
        _ = try await api.cancel(conversationId: "chat", runId: run.id, token: "fixture-token")
        _ = try await api.cancel(conversationId: "chat", runId: run.id, partial: inference, token: "fixture-token")
        _ = try await api.retry(conversationId: "chat", runId: run.id, deviceId: "device", modelRef: nil, token: "fixture-token")
        _ = try await api.retry(conversationId: "chat", runId: run.id, deviceId: "device", modelRef: "cloud:default", maxSteps: 10, token: "fixture-token")
        _ = try await api.resume(conversationId: "chat", runId: run.id, token: "fixture-token")
        _ = try await api.regenerate(conversationId: "chat", request: .init(messageId: "message", deviceId: "device"), token: "fixture-token")
        _ = try await api.steer(conversationId: "chat", request: .init(runId: run.id, message: message), token: "fixture-token")
        _ = try await api.recover(conversationId: "chat", request: .init(runId: run.id, deviceId: "device", callIds: []), token: "fixture-token")
        await #expect(throws: (any Error).self) { try await api.updateTitle(id: "chat", request: .init(action: "set", title: "Title"), token: "fixture-token") }
        _ = try await api.keep(conversationId: "chat", token: "fixture-token")
        #expect(try await api.usage(id: "chat", runId: nil, cursor: nil, token: "fixture-token").items.isEmpty)
        #expect(try await api.models(token: "fixture-token").count == 1)
        #expect(try await api.models(token: "fixture-token", scenario: "chat").count == 1)
        _ = try await api.featureModels(feature: "title", token: "fixture-token")
        #expect(await !api.historySyncPending(token: "fixture-token"))
        try await api.purgeMemory(token: "fixture-token")
        try await api.purgeMemory(owner: "owner", token: "fixture-token")
        await backend.setFailModels(true)
        await #expect(throws: (any Error).self) { try await api.models(token: "fixture-token") }
        try await api.delete(conversationId: "chat", token: "fixture-token")
        #expect(await backend.deletes == ["chat"])
        await client.stop(); await server.stop()
    }

    @Test func canonicalCachePreservesDraftsReceiptsAndExecutionClaimsAcrossClients() async throws {
        let backend = AskTestAPI(), storage = try AskConversationCache.inMemory()
        let (client, server) = try await pair(api: backend, cache: storage)
        let cache = FeatureAskCache(connection: client, generation: { 0 })
        let value = AskConversation(id: "chat", title: "Title", revision: 1, updatedAt: Date(), messages: [])
        try await cache.save(value, owner: "owner")
        #expect(try await cache.load(id: "chat", owner: "owner")?.title == value.title)
        #expect(try await cache.list(owner: "owner").count == 1)
        let draft = AskDraft(text: "Unsent", includeScreenshot: false)
        try await cache.saveDraft(draft, key: "saved-chat:handoff:fixture", owner: "owner")
        #expect(try await cache.draft(key: "saved-chat:handoff:fixture", owner: "owner") == draft)
        #expect(try await cache.savedChatDrafts(owner: "owner").count == 1)
        let run = AskRun(id: "run", deviceId: "device", status: "waiting_tool", steps: 1, updatedAt: Date(), tools: [], pending: [])
        let identity = AskExecutionIdentity(owner: "owner", conversation: value, run: run, callId: "call", kind: "tool")
        let audit = AskExecutionAudit(identity: identity, toolVersion: "1", argumentsHash: "sha256:fixture")
        #expect(try await cache.claimExecution(audit, owner: "owner"))
        #expect(try await !cache.claimExecution(audit, owner: "owner"))
        let receipt = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "call", content: "Saved", isError: false)
        try await cache.saveReceipt(.tool(receipt), identity: identity, owner: "owner")
        try await cache.recordExecution(id: identity.key, event: .acknowledged, owner: "owner")
        #expect(try await cache.execution(id: identity.key, owner: "owner")?.receipt == .tool(receipt))
        #expect(try await cache.executions(conversationId: "chat", owner: "owner").count == 1)
        let deniedID = AskExecutionIdentity(owner: "owner", conversation: value, run: run, callId: "denied", kind: "tool")
        let denied = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "denied", content: "Denied", isError: true,
            harness: .init(version: 1, outcome: .init(status: "denied", eventDispatched: false)))
        try await cache.saveRejectedToolReceipt(audit: .init(identity: deniedID, toolVersion: "1", argumentsHash: "sha256:denied"), receipt: denied, owner: "owner")
        try await cache.associateTool(id: "run/legacy", conversationId: "chat", owner: "owner")
        #expect(try await cache.claimTool(id: "run/legacy", owner: "owner"))
        let legacy = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "legacy", content: "Legacy", isError: false)
        try await cache.saveToolResult(legacy, owner: "owner")
        #expect(try await cache.toolResult(id: "run/legacy", owner: "owner") == legacy)
        try await cache.delete(id: "chat", owner: "owner")
        #expect(try await cache.load(id: "chat", owner: "owner") == nil)
        await client.stop(); await server.stop()
    }
}

private actor BootstrapRetryFixture {
    let snapshot: FeatureAuth
    private(set) var calls = 0
    init(snapshot: FeatureAuth) { self.snapshot = snapshot }
    func reply() throws -> Data {
        calls += 1
        if calls < 3 { throw FeatureRPC.Failure.busy }
        return try JSONEncoder().encode(snapshot)
    }
}

private actor CacheDisconnectFixture {
    private var counts: [String: Int] = [:]
    func count(_ method: String) -> Int { counts[method, default: 0] }
    func shouldDisconnect(_ method: String) -> Bool {
        counts[method, default: 0] += 1
        return ["cache.draft.11", "cache.saveDraft.10"].contains(method) && counts[method] == 1
    }
}

private actor CacheAuthRetryFixture {
    private(set) var generation = 0
    private(set) var refreshes = 0
    private(set) var writes = 0
    func refresh(owner: String) -> Bool {
        guard owner == "owner" else { return false }
        generation = 1; refreshes += 1
        return true
    }
    func makeStale() { generation = 0 }
    func handle(_ method: String, payload: Data) throws -> Data {
        let call = try JSONDecoder().decode(FeatureAskCall.self, from: payload)
        let reply: FeatureAskReply
        if call.generation != 1 {
            reply = .init(payload: nil, error: .init(AuthError.unauthorized))
        } else if method == "cache.draft.11" {
            reply = .init(payload: try JSONEncoder().encode(AskDraft(text: "Unsent")), error: nil)
        } else {
            writes += 1
            reply = .init(payload: try JSONEncoder().encode(FeatureRPC.Empty()), error: nil)
        }
        return try JSONEncoder().encode(reply)
    }
}
