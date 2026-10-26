import Foundation
import Testing
@testable import Typeflux

private final class DeviceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date {
        lock.withLock { value }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private actor DeviceTestSession {
    var active: String? = "user-a"
    var replacement: String?
    func use(_ value: String?) {
        active = value; replacement = nil
    }

    func rotate(_ value: String) {
        replacement = value
    }

    func token(_ owner: String) -> String? {
        active == owner ? replacement ?? owner : nil
    }

    func account(_ token: String) throws -> String {
        guard let active, (replacement ?? active) == token else { throw AuthError.unauthorized }
        return active
    }
}

private actor DeviceTestTransport: AskDeviceTransporting {
    var offline = true
    var hold = false
    var loseAcknowledgment = false
    var waiter: CheckedContinuation<Void, Never>?
    var attempts: [(String, String, AskDeviceSnapshot)] = []
    var values: [String: [String: AskDeviceSnapshot]] = [:]
    func connect() {
        offline = false
    }

    func loseNextAcknowledgment() {
        loseAcknowledgment = true
    }

    func pause() {
        hold = true
    }

    func release() {
        hold = false; waiter?.resume(); waiter = nil
    }

    func seed(_ value: AskDeviceSnapshot, id: String, token: String) {
        values[token, default: [:]][id] = value
    }

    func list(token: String, offset: Int) async throws -> [AskConversationSummary] {
        if offline { throw AskStreamError.requestFailed }
        return Array((values[token] ?? [:]).values.compactMap { value -> AskConversationSummary? in
            guard !value.deleted, let c = value.conversation else { return nil }
            return .init(id: c.id, title: c.title, updatedAt: c.updatedAt)
        }.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(offset).prefix(50))
    }

    func snapshot(id: String, token: String) async throws -> AskDeviceSnapshot? {
        if offline { throw AskStreamError.requestFailed }
        return values[token]?[id]
    }

    func put(id: String, snapshot: AskDeviceSnapshot, token: String) async throws {
        attempts.append((token, id, snapshot))
        if hold { await withCheckedContinuation { waiter = $0 } }
        try Task.checkCancellation()
        if offline { throw AskStreamError.requestFailed }
        if (values[token]?[id]?.revision ?? 0) < snapshot.revision { values[token, default: [:]][id] = snapshot }
        if loseAcknowledgment { loseAcknowledgment = false; throw URLError(.networkConnectionLost) }
    }

    func webTool(name _: String, arguments _: String, token _: String) async throws -> AskBuiltinToolOutput {
        .init(text: "Public page", isError: false)
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor struct AskDeviceAPITests {
    private let device = UUID().uuidString.lowercased()
    private func request(model: String = "custom:test", temporary: Bool = false) -> AskSendRequest {
        var value = AskSendRequest(
            id: UUID().uuidString.lowercased(),
            deviceId: device,
            text: "Build a game",
            tools: [],
            modelRef: model
        )
        value.deviceCreate = true; value.temporary = temporary ? true : nil
        return value
    }

    private func make(root: URL, legacy: AskTestAPI, transport: DeviceTestTransport, session: DeviceTestSession,
                      clock: DeviceTestClock, exclusive: Bool = false) -> AskDeviceAPI {
        AskDeviceAPI(
            root: root,
            legacy: legacy,
            transport: transport,
            resolveAccount: { try await session.account($0) },
            refreshToken: { await session.token($0) },
            requiresExclusiveAccess: exclusive,
            factory: { _, directory in AskLocalEngine(
                directory: directory,
                now: { clock.now() },
                allowsCloudModels: true
            ) }
        )
    }

    private func environment(_ body: (
        AskDeviceAPI,
        AskTestAPI,
        DeviceTestTransport,
        DeviceTestSession,
        DeviceTestClock,
        URL
    ) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-api-\(UUID().uuidString)")
        let legacy = AskTestAPI(), transport = DeviceTestTransport(), session = DeviceTestSession(),
            clock = DeviceTestClock()
        let api = make(root: root, legacy: legacy, transport: transport, session: session, clock: clock)
        do { try await body(api, legacy, transport, session, clock, root) }
        catch { await api.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
        await api.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    private func finish(_ api: AskDeviceAPI, _ value: AskConversation,
                        token: String = "user-a") async throws -> AskConversation {
        let run = try #require(value.run), inference = try #require(run.inference)
        return try await api.inferenceResult(conversationId: value.id,
                                             request: .init(
                                                 runId: run.id,
                                                 deviceId: run.deviceId,
                                                 inferenceId: inference.id,
                                                 content: "Game completed"
                                             ), token: token)
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0 ..< 400 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the asynchronous synchronization worker")
    }

    @Test func `cloud stored conversation recovers locally without server orchestration or a user message`() async throws {
        try await environment { api, legacy, _, _, _, _ in
            let id = UUID().uuidString.lowercased()
            let original = try await api.send(conversationId: id, request: request(), token: "user-a")
            let run = try #require(original.run)
            let recovered = try await api.recover(conversationId: id,
                request: .init(runId: run.id, deviceId: run.deviceId, callIds: [], inferenceId: run.inference?.id), token: "user-a")
            #expect(recovered.run?.id == run.id && recovered.run?.inference?.id != run.inference?.id)
            #expect(recovered.messages.filter { $0.role == "user" } == original.messages.filter { $0.role == "user" })
            #expect(await legacy.recoveries.isEmpty)
            #expect(await legacy.sends.isEmpty)
            let completed = try await finish(api, recovered)
            #expect(completed.run?.status == "completed")
            #expect(try await api.hasPendingSynchronization(token: "user-a"))
        }
    }

    @Test func `offline execution survives long inference and never calls server orchestration`() async throws {
        try await environment { api, legacy, _, _, clock, _ in
            let id = UUID().uuidString.lowercased()
            let initial = try await api.send(conversationId: id, request: request(), token: "user-a")
            #expect(initial.run?.status == "waiting_inference")
            clock.advance(7200)
            #expect(try await api.conversation(id: id, token: "user-a").run?.status == "waiting_inference")
            let done = try await finish(api, initial)
            #expect(done.run?.status == "completed")
            let repeated = try await finish(api, initial)
            #expect(repeated.revision == done.revision)
            #expect(repeated.messages == done.messages)
            #expect(await api.historySyncPending(token: "user-a"))
            #expect(done.messages.last?.text == "Game completed")
            #expect(try await api.hasPendingSynchronization(token: "user-a"))
            #expect(await legacy.sends.isEmpty)
            #expect(await legacy.inferenceResults.isEmpty)
            #expect(try await api.list(token: "user-a", offset: 0).map(\.id) == [id])
        }
    }

    @Test func `slow synchronization cannot block result application or drop newer snapshots`() async throws {
        try await environment { api, _, transport, _, _, _ in
            await transport.connect(); await transport.pause()
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(),
                token: "user-a"
            )
            try await wait { await transport.attempts.count == 1 }
            let done = try await finish(api, initial)
            #expect(done.run?.status == "completed")
            await transport.release()
            try await wait { try await !api.hasPendingSynchronization(token: "user-a") }
            #expect(await transport.values["user-a"]?[done.id]?.revision == done.revision)
            #expect(await transport.values["user-a"]?[done.id]?.conversation?.run?.inference == nil)
        }
    }

    @Test func `restart restores execution and retries durable synchronization without replaying model calls`(
    ) async throws {
        try await environment { api, legacy, transport, session, clock, root in
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(),
                token: "user-a"
            )
            await api.shutdown()
            let restarted = make(root: root, legacy: legacy, transport: transport, session: session, clock: clock)
            let restored = try await restarted.conversation(id: initial.id, token: "user-a")
            #expect(restored.run?.inference?.id == initial.run?.inference?.id)
            let done = try await finish(restarted, restored)
            await transport.connect()
            try await wait { try await !restarted.hasPendingSynchronization(token: "user-a") }
            #expect(await transport.values["user-a"]?[done.id]?.conversation?.messages.last?.text == "Game completed")
            #expect(await legacy.sends.isEmpty)
            await restarted.shutdown()
        }
    }

    @Test func `accounts cannot read each others local execution snapshots`() async throws {
        try await environment { api, legacy, transport, session, _, _ in
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(),
                token: "user-a"
            )
            await session.use("user-b")
            await #expect(throws: AuthError.self) { try await api.conversation(id: initial.id, token: "user-a") }
            #expect(try await api.list(token: "user-b", offset: 0).isEmpty)
            #expect(await transport.values["user-b"]?[initial.id] == nil)
            #expect(await legacy.sends.isEmpty)
        }
    }

    @Test func `history replicas cannot authorize tools or create a competing local run`() async throws {
        try await environment { api, _, transport, _, _, _ in
            await transport.connect()
            let id = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
            let value = AskConversation(id: id, title: "Other Mac", revision: 8, updatedAt: Date(), messages: [],
                                        run: .init(
                                            id: UUID().uuidString.lowercased(),
                                            deviceId: other,
                                            status: "waiting_inference",
                                            steps: 0,
                                            updatedAt: Date(),
                                            tools: [],
                                            pending: []
                                        ))
            await transport.seed(.init(deviceId: other, revision: 8, conversation: value), id: id, token: "user-a")
            let observed = try await api.conversation(id: id, token: "user-a")
            #expect(observed.run?.deviceId == other)
            await #expect(throws: AskLocalError.self) { try await api.send(
                conversationId: id,
                request: request(),
                token: "user-a"
            ) }
            await #expect(throws: AskLocalError.self) { try await api.cancel(
                conversationId: id,
                runId: value.run!.id,
                token: "user-a"
            ) }
            await #expect(throws: AskLocalError.self) { try await api.retry(
                conversationId: id,
                runId: value.run!.id,
                deviceId: device,
                modelRef: nil,
                token: "user-a"
            ) }
        }
    }

    @Test func `temporary conversations never enter the sync outbox`() async throws {
        try await environment { api, _, transport, _, _, _ in
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(temporary: true),
                token: "user-a"
            )
            _ = try await finish(api, initial)
            #expect(try await !api.hasPendingSynchronization(token: "user-a"))
            try await api.delete(conversationId: initial.id, token: "user-a")
            #expect(await transport.attempts.isEmpty)
        }
    }

    @Test func `offline deletion survives restart and cannot resurrect from history`() async throws {
        try await environment { api, legacy, transport, session, clock, root in
            let value = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(),
                token: "user-a"
            )
            try await api.delete(conversationId: value.id, token: "user-a")
            await api.shutdown()
            let restarted = make(root: root, legacy: legacy, transport: transport, session: session, clock: clock)
            await transport.connect()
            #expect(try await restarted.list(token: "user-a", offset: 0).isEmpty)
            try await wait { try await !restarted.hasPendingSynchronization(token: "user-a") }
            #expect(await transport.values["user-a"]?[value.id]?.deleted == true)
            await #expect(throws: AskLocalError.self) { try await restarted.conversation(id: value.id, token: "user-a")
            }
            await restarted.shutdown()
        }
    }

    @Test func `Cloud model orchestration also stays on the Mac`() async throws {
        try await environment { api, legacy, _, _, _, _ in
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(model: "cloud:default"),
                token: "user-a"
            )
            #expect(initial.run?.inference?.payload.contains("cloud:default") == true)
            let done = try await finish(api, initial)
            #expect(done.run?.status == "completed")
            #expect(done.usage?.total.external == 0)
            #expect(done.usage?.total.creditsText == "—")
            #expect(await legacy.sends.isEmpty)
        }
    }

    @Test func `exhausted credits pause locally and resume with a fresh inference identity`() async throws {
        try await environment { api, _, _, _, _, _ in
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(model: "cloud:default"),
                token: "user-a"
            )
            let run = try #require(initial.run), inference = try #require(run.inference)
            let paused = try await api.inferenceResult(conversationId: initial.id,
                                                       request: .init(
                                                           runId: run.id,
                                                           deviceId: device,
                                                           inferenceId: inference.id,
                                                           content: "",
                                                           failed: true,
                                                           errorCode: "CREDITS_EXHAUSTED"
                                                       ), token: "user-a")
            #expect(paused.run?.isPausedForCredits == true)
            let resumed = try await api.resume(conversationId: initial.id, runId: run.id, token: "user-a")
            #expect(resumed.run?.status == "waiting_inference")
            #expect(resumed.run?.inference?.id != inference.id)
            #expect(resumed.run?.id == run.id)
        }
    }

    @Test func `terminal legacy conversations migrate before their next task`() async throws {
        try await environment { api, legacy, transport, _, _, _ in
            await transport.connect()
            let id = UUID().uuidString.lowercased()
            await legacy.seed(.init(id: id, title: "Earlier chat", revision: 5, updatedAt: Date(), messages: [
                .init(id: "old", role: "user", text: "Earlier question", createdAt: Date())
            ]))
            _ = try await api.conversation(id: id, token: "user-a")
            var next = request(); next.deviceCreate = nil
            let value = try await api.send(conversationId: id, request: next, token: "user-a")
            #expect(value.messages.first?.text == "Earlier question")
            #expect(value.run?.status == "waiting_inference")
            #expect(await legacy.sends.isEmpty)
        }
    }

    @Test func `a lost migration acknowledgment never dispatches before ownership is confirmed`() async throws {
        try await environment { api, legacy, transport, _, _, _ in
            await transport.connect()
            let id = UUID().uuidString.lowercased()
            await legacy.seed(.init(id: id, title: "Legacy", revision: 4, updatedAt: Date(), messages: []))
            _ = try await api.conversation(id: id, token: "user-a")
            await transport.loseNextAcknowledgment()
            var next = request(); next.deviceCreate = nil
            await #expect(throws: URLError.self) {
                try await api.send(conversationId: id, request: next, token: "user-a")
            }
            let before = try await api.conversation(id: id, token: "user-a")
            #expect(before.run == nil)
            #expect(before.messages.isEmpty)
            let admitted = try await api.send(conversationId: id, request: next, token: "user-a")
            #expect(admitted.run?.status == "waiting_inference")
            #expect(admitted.messages.count(where: { $0.id == next.id }) == 1)
            #expect(await legacy.sends.isEmpty)
        }
    }

    @Test func `token refresh admits late local results only within the original account`() async throws {
        try await environment { api, _, _, session, _, _ in
            let value = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(),
                token: "user-a"
            )
            await session.rotate("rotated-a")
            let done = try await finish(api, value)
            #expect(done.run?.status == "completed")
            await session.use("user-b")
            await #expect(throws: AuthError.self) { try await api.conversation(id: value.id, token: "user-a") }
        }
    }

    @Test func `retrying a failed legacy task creates its new run on the Mac`() async throws {
        try await environment { api, legacy, transport, _, _, _ in
            await transport.connect()
            let id = UUID().uuidString.lowercased(), runID = UUID().uuidString.lowercased()
            await legacy.seed(.init(id: id, title: "Failed task", revision: 5, updatedAt: Date(), messages: [
                .init(id: "question", role: "user", text: "Build a game", createdAt: Date())
            ], run: .init(
                id: runID,
                deviceId: device,
                status: "failed",
                steps: 0,
                updatedAt: Date(),
                tools: [],
                pending: [],
                modelRef: "custom:test",
                budgetEnabled: true,
                budgetRootId: UUID().uuidString.lowercased(),
                budgetDeadline: .distantPast
            )))
            _ = try await api.conversation(id: id, token: "user-a")
            let retried = try await api.retry(
                conversationId: id,
                runId: runID,
                deviceId: device,
                modelRef: nil,
                token: "user-a"
            )
            #expect(retried.run?.id != runID)
            #expect(retried.run?.status == "waiting_inference")
            #expect(await legacy.retryModels.isEmpty)
        }
    }

    @Test func `approval rename regeneration cancellation and usage retain device ownership`() async throws {
        try await environment { api, legacy, _, _, _, _ in
            var question = request()
            question.clientToolApproval = true
            question.memory = AskMemory(global: "Private preference")
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: question,
                token: "user-a"
            )
            let run = try #require(initial.run), inference = try #require(run.inference)
            let plan = AskToolCall(
                id: "plan",
                type: "function",
                function: .init(name: "update_plan", arguments: #"{"items":[{"step":"Build","status":"completed"}]}"#)
            )
            let waiting = try await api.inferenceResult(conversationId: initial.id,
                                                        request: .init(
                                                            runId: run.id,
                                                            deviceId: device,
                                                            inferenceId: inference.id,
                                                            content: "",
                                                            toolCalls: [plan]
                                                        ), token: "user-a")
            #expect(waiting.run?.status == "waiting_tool")
            let next = try await api.result(conversationId: initial.id,
                                            request: .init(
                                                approveExecution: true,
                                                runId: run.id,
                                                deviceId: device,
                                                toolCallId: plan.id,
                                                content: "",
                                                isError: false
                                            ), token: "user-a")
            #expect(next.run?.plan?.first?.step == "Build")
            let done = try await finish(api, next)
            let renamed = try await api.updateTitle(
                id: done.id,
                request: .init(action: "rename", title: "My game"),
                token: "user-a"
            )
            #expect(renamed.title == "My game")
            let page = try await api.usage(id: done.id, runId: nil, cursor: nil, token: "user-a")
            #expect(page.items.count == 2)
            let answerID = try #require(done.messages.last?.id)
            let regenerated = try await api.regenerate(conversationId: done.id,
                                                       request: .init(
                                                           messageId: answerID,
                                                           deviceId: device,
                                                           modelRef: "custom:test"
                                                       ), token: "user-a")
            #expect(regenerated.run?.status == "waiting_inference")
            let regeneratedRun = try #require(regenerated.run)
            let cancelled = try await api.cancel(
                conversationId: done.id,
                runId: regeneratedRun.id,
                partial: nil,
                token: "user-a"
            )
            #expect(cancelled.run?.status == "cancelled")
            try await api.purgeMemory(token: "user-a")
            let cleared = try await api.conversation(id: done.id, token: "user-a")
            #expect(cleared.memory == nil)
            let models = try await api.models(token: "user-a")
            let askModels = try await api.models(token: "user-a", scenario: "ask")
            #expect(models.map(\.id) == askModels.map(\.id))
            let feature = try await api.featureModels(feature: "ask-anything", token: "user-a")
            #expect(feature == nil)
            #expect(await legacy.sends.isEmpty)
            #expect(await legacy.results.isEmpty)
        }
    }

    @Test func `keeping a temporary conversation starts history synchronization only after promotion`() async throws {
        try await environment { api, _, transport, _, _, _ in
            let initial = try await api.send(
                conversationId: UUID().uuidString.lowercased(),
                request: request(temporary: true),
                token: "user-a"
            )
            #expect(await transport.attempts.isEmpty)
            let kept = try await api.keep(conversationId: initial.id, token: "user-a")
            #expect(kept.id == initial.id)
            #expect(await api.historySyncPending(token: "user-a"))
            let list = try await api.list(token: "user-a", offset: 0)
            #expect(list.map(\.id).contains(initial.id))
        }
    }
}


extension AskDeviceAPITests {
    @Test func exclusiveAccountRejectsBeforeSyncAndAllowsAnIndependentAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DeviceTestTransport(), session = DeviceTestSession(), legacy = AskTestAPI()
        let api = make(root: root, legacy: legacy, transport: transport, session: session,
                       clock: DeviceTestClock(), exclusive: true)
        var lease: AskConversationDirectoryLease? = try .init(directory: root.appendingPathComponent("user-a"))
        #expect(lease != nil)
        await #expect(throws: AskConversationOwnershipError.inUse) {
            _ = try await api.send(conversationId: "chat", request: request(), token: "user-a")
        }
        await #expect(throws: AskConversationOwnershipError.inUse) {
            _ = try await api.list(token: "user-a", offset: 0)
        }
        await #expect(throws: AskConversationOwnershipError.inUse) {
            try await api.delete(conversationId: "chat", token: "user-a")
        }
        #expect(await transport.attempts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("user-a/sync.json").path))
        await session.use("user-b")
        _ = try await api.send(conversationId: "other", request: request(temporary: true), token: "user-b")
        await session.use("user-a")
        lease = nil
        let admitted = try await api.send(conversationId: "chat", request: request(temporary: true), token: "user-a")
        #expect(admitted.run?.status == "waiting_inference")
        #expect(throws: AskConversationOwnershipError.inUse) {
            try AskConversationDirectoryLease(directory: root.appendingPathComponent("user-a"))
        }
        await api.shutdown()
        // Stopping synchronization alone is not a transfer of execution ownership.
        #expect(throws: AskConversationOwnershipError.inUse) {
            try AskConversationDirectoryLease(directory: root.appendingPathComponent("user-a"))
        }
    }
}
