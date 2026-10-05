@testable import Typeflux
import XCTest

final class AskLocalEngineReentrancyTests: XCTestCase {
    private var directory: URL!
    private let device = "device-1"
    private let secret = "memory-before-purge-sentinel"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-local-reentrancy-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func send(_ engine: AskLocalEngine, id: String = "conversation", memoryOff: Bool = false) async throws -> AskConversation {
        let tools = await AskLocalTools.builtins
        var request = AskSendRequest(id: UUID().uuidString, deviceId: device, text: "Read the page", tools: tools,
                                     modelRef: "custom:model", memory: AskMemory(global: secret))
        request.memoryOff = memoryOff
        return try await engine.send(conversationId: id, request: request, token: "")
    }

    private func plan(_ id: String, status: String) -> AskToolCall {
        AskToolCall(id: id, type: "function", function: .init(name: "update_plan", arguments:
            "{\"items\":[{\"step\":\"Read\",\"status\":\"\(status)\"}]}"))
    }

    private func steering(_ conversation: AskConversation) -> AskSteerRequest {
        AskSteerRequest(runId: conversation.run!.id, message: AskSendRequest(
            id: "steering", deviceId: device, text: "Also explain the result", tools: []))
    }

    /// Suspend a configured search at URLSession while the actor accepts other
    /// calls. P08 disables general web_fetch, so the fixture uses web_search to
    /// keep testing the same late server-tool completion without bypassing it.
    /// Always release and collect the task.
    private func fetch(_ fixture: SuspendedLocalFetch, engine: AskLocalEngine, conversation: AskConversation,
                       before: [AskToolCall] = [], after: [AskToolCall] = [],
                       whileSuspended: (AskInferenceResult) async throws -> Void) async throws -> AskConversation {
        let call = AskToolCall(id: "fetch", type: "function", function: .init(name: "web_search", arguments:
            "{\"query\":\"fixture\"}"))
        let run = try XCTUnwrap(conversation.run)
        let request = AskInferenceResult(runId: run.id, deviceId: device, inferenceId: try XCTUnwrap(run.inference?.id),
                                         content: "", toolCalls: before + [call] + after)
        let task = Task {
            try await engine.inferenceResult(conversationId: conversation.id, request: request, token: "")
        }
        await fulfillment(of: [fixture.started], timeout: 5)
        do {
            try await whileSuspended(request)
        } catch {
            fixture.release()
            _ = try? await task.value
            throw error
        }
        fixture.release()
        return try await task.value
    }

    private func assertPurged(_ conversation: AskConversation, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(conversation.memory, file: file, line: line)
        XCTAssertNil(conversation.memoryOff, file: file, line: line)
        XCTAssertFalse(conversation.run?.inference?.payload.contains(secret) == true, file: file, line: line)
    }

    private func assertPersisted(_ expected: AskConversation, file: StaticString = #filePath, line: UInt = #line) async throws {
        let reopened = AskLocalEngine(directory: directory)
        let actual = try await reopened.conversation(id: expected.id, token: "")
        // Compare persisted values with second-precision dates and stable key
        // order; JSONValue's raw schema bytes may reorder on decoding.
        let encoder = AskCoding.encoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(actual), try encoder.encode(expected), file: file, line: line)
        assertPurged(actual, file: file, line: line)
    }

    func testPurgeDuringFetchNeverRestoresMemoryOnReadOrReopen() async throws {
        // Repeat the exact ordering without timing sleeps, including memoryOff
        // and failed fetches. Receipt retries must not execute the request twice.
        for iteration in 0 ..< 6 {
            let fixture = SuspendedLocalFetch(status: iteration == 5 ? 503 : 200)
            defer { fixture.close() }
            let engine = AskLocalEngine(directory: directory, webTools: fixture.tools)
            let initial = try await send(engine, id: "conversation-\(iteration)", memoryOff: iteration.isMultiple(of: 2))
            var purgedRevision: Int64 = 0
            var receipt: AskInferenceResult!
            let result = try await fetch(fixture, engine: engine, conversation: initial) { request in
                receipt = request
                let running = try await engine.conversation(id: initial.id, token: "")
                XCTAssertEqual(running.run?.pending.map(\.id), ["fetch"])
                XCTAssertEqual(running.revision, initial.revision + 1)
                try await engine.purgeMemory(token: "")
                let purged = try await engine.conversation(id: initial.id, token: "")
                assertPurged(purged)
                XCTAssertEqual(purged.revision, running.revision + 1)
                purgedRevision = purged.revision
                let duplicate = try await engine.inferenceResult(conversationId: initial.id,
                                                                 request: request, token: "")
                XCTAssertEqual(duplicate, purged)
            }
            assertPurged(result)
            XCTAssertEqual(result.revision, purgedRevision + 1)
            XCTAssertEqual(result.run?.status, "waiting_inference")
            let receipts = result.messages.filter { $0.toolCallId == "fetch" }
            XCTAssertEqual(receipts.count, 1)
            XCTAssertEqual(receipts.first?.isError, iteration == 5)
            let duplicate = try await engine.inferenceResult(conversationId: initial.id, request: receipt, token: "")
            XCTAssertEqual(duplicate, result)
            let read = try await engine.conversation(id: initial.id, token: "")
            XCTAssertEqual(read, result)
            try await assertPersisted(result)
            XCTAssertEqual(fixture.requestCount, 1)
        }
    }

    func testPurgeAndSteeringKeepBothPlanDeltasAndDeviceReceipts() async throws {
        for purgeFirst in [true, false] {
            let fixture = SuspendedLocalFetch()
            defer { fixture.close() }
            let engine = AskLocalEngine(directory: directory, webTools: fixture.tools)
            let initial = try await send(engine, id: purgeFirst ? "purge-first" : "steer-first")
            let steer = steering(initial)
            let browser = AskToolCall(id: "browser", type: "function",
                                      function: .init(name: "browser", arguments: "{}"))
            var latestRevision: Int64 = 0
            var result = try await fetch(fixture, engine: engine, conversation: initial,
                                         before: [plan("plan-before", status: "in_progress")],
                                         after: [plan("plan-after", status: "completed"), browser]) { _ in
                if purgeFirst { try await engine.purgeMemory(token: "") }
                let queued = try await engine.steer(conversationId: initial.id, request: steer, token: "")
                XCTAssertEqual(queued.run?.plan, [AskPlanItem(step: "Read", status: "in_progress")])
                let replay = try await engine.steer(conversationId: initial.id, request: steer, token: "")
                XCTAssertEqual(replay.revision, queued.revision)
                if !purgeFirst { try await engine.purgeMemory(token: "") }
                latestRevision = try await engine.conversation(id: initial.id, token: "").revision
            }
            assertPurged(result)
            XCTAssertEqual(result.revision, latestRevision + 2)
            XCTAssertEqual(result.run?.plan, [AskPlanItem(step: "Read", status: "completed")])
            XCTAssertEqual(result.run?.status, "waiting_tool")
            XCTAssertEqual(result.run?.pending.map(\.id), ["browser"])
            XCTAssertEqual(result.messages.compactMap(\.toolCallId), ["plan-before", "fetch", "plan-after"])
            XCTAssertFalse(result.messages.contains { $0.id == steer.id })
            let deviceReceipt = AskToolResultRequest(runId: initial.run!.id, deviceId: device,
                                                     toolCallId: "browser", content: "Page read", isError: false)
            let waitingRevision = result.revision
            result = try await engine.result(conversationId: initial.id, request: deviceReceipt, token: "")
            XCTAssertEqual(result.revision, waitingRevision + 1)
            XCTAssertEqual(result.messages.suffix(2).map(\.role), ["tool", "user"])
            XCTAssertEqual(result.messages.filter { $0.id == steer.id }.count, 1)
            XCTAssertEqual(result.messages.compactMap(\.toolCallId), ["plan-before", "fetch", "plan-after", "browser"])
            XCTAssertEqual(result.run?.extraSteps, AskLocalEngine.steeringStepBonus)
            XCTAssertTrue(result.run?.inference?.payload.contains(steer.text) == true)
            let duplicate = try await engine.result(conversationId: initial.id, request: deviceReceipt, token: "")
            XCTAssertEqual(duplicate, result)
            try await assertPersisted(result)
            let saved = try AskCoding.decoder().decode(AskLocalRecord.self,
                from: Data(contentsOf: directory.appendingPathComponent(initial.id + ".json")))
            XCTAssertEqual(saved.cloudCalls, 1, "Only the web request consumes the quota")
            XCTAssertNil(saved.steering)
            XCTAssertEqual(fixture.requestCount, 1)
        }
    }

    func testPurgeAndCancelRejectLateFetchAndKeepCommittedPlan() async throws {
        for purgeFirst in [true, false] {
            let fixture = SuspendedLocalFetch()
            defer { fixture.close() }
            let engine = AskLocalEngine(directory: directory, webTools: fixture.tools)
            let initial = try await send(engine, id: purgeFirst ? "purge-first" : "cancel-first")
            var cancelled: AskConversation!
            let result = try await fetch(fixture, engine: engine, conversation: initial,
                                         before: [plan("plan-before", status: "in_progress")],
                                         after: [plan("plan-after", status: "completed")]) { _ in
                _ = try await engine.steer(conversationId: initial.id, request: steering(initial), token: "")
                if purgeFirst { try await engine.purgeMemory(token: "") }
                _ = try await engine.cancel(conversationId: initial.id, runId: initial.run!.id, token: "")
                if !purgeFirst { try await engine.purgeMemory(token: "") }
                cancelled = try await engine.conversation(id: initial.id, token: "")
            }
            XCTAssertEqual(result, cancelled)
            XCTAssertEqual(result.run?.status, "cancelled")
            XCTAssertEqual(result.run?.plan, [AskPlanItem(step: "Read", status: "in_progress")])
            XCTAssertEqual(result.messages.compactMap(\.toolCallId), ["plan-before", "fetch", "plan-after"])
            XCTAssertTrue(result.messages.suffix(2).allSatisfy { $0.isError == true })
            XCTAssertFalse(result.messages.contains { $0.id == "steering" })
            try await assertPersisted(result)
            XCTAssertEqual(fixture.requestCount, 1)
        }
    }

    func testLateFetchCannotOverwriteANewRunAfterPurgeAndCancel() async throws {
        let fixture = SuspendedLocalFetch()
        defer { fixture.close() }
        let engine = AskLocalEngine(directory: directory, webTools: fixture.tools)
        let initial = try await send(engine)
        var restarted: AskConversation!
        let result = try await fetch(fixture, engine: engine, conversation: initial) { _ in
            try await engine.purgeMemory(token: "")
            _ = try await engine.cancel(conversationId: initial.id, runId: initial.run!.id, token: "")
            restarted = try await engine.retry(conversationId: initial.id, runId: initial.run!.id,
                                                deviceId: device, modelRef: nil, token: "")
        }
        XCTAssertNotEqual(result.run?.id, initial.run?.id)
        XCTAssertEqual(result, restarted)
        try await assertPersisted(result)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testDeletedConversationIsNotReturnedOrRecreatedByLateFetch() async throws {
        let fixture = SuspendedLocalFetch()
        defer { fixture.close() }
        let engine = AskLocalEngine(directory: directory, webTools: fixture.tools)
        let initial = try await send(engine)
        do {
            _ = try await fetch(fixture, engine: engine, conversation: initial) { _ in
                try await engine.purgeMemory(token: "")
                try await engine.delete(conversationId: initial.id, token: "")
            }
            XCTFail("A deleted conversation must not be returned from a stale snapshot")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("ask.local.notFound"))
        }
        let listed = try await engine.list(token: "", offset: 0)
        XCTAssertTrue(listed.isEmpty)
        let reopened = AskLocalEngine(directory: directory)
        let persisted = try await reopened.list(token: "", offset: 0)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(fixture.requestCount, 1)
    }
}

extension AskLocalEngineReentrancyTests {
    func testBudgetedRetryLateUsageAndMemoryPurgeWhileNewRunIsSuspended() async throws {
        for cancelRetry in [false, true] {
            let fixture = SuspendedLocalFetch()
            defer { fixture.close() }
            let engine = AskLocalEngine(directory: directory, webTools: fixture.tools, budgetEnabled: true)
            let initial = try await send(engine, id: "budget-\(cancelRetry)")
            let old = try staleReceipt(XCTUnwrap(initial.run))
            let notesFile = directory.appendingPathComponent("notes-\(cancelRetry).json")
            let notes = AskMemoryNoteStore(fileURL: notesFile)
            let note = try notes.add(secret, owner: "source-owner")
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            _ = try await engine.cancel(conversationId: initial.id, runId: old.runId, token: "")
            let retry = try await engine.retry(conversationId: initial.id, runId: old.runId,
                                               deviceId: device, modelRef: nil, token: "")
            var beforeRelease: AskConversation!
            var result = try await fetch(fixture, engine: engine, conversation: retry) { _ in
                XCTAssertTrue(try notes.remove(id: note.id, owner: "source-owner"))
                let reopenedNotes = AskMemoryNoteStore(fileURL: notesFile)
                reopenedNotes.recoverInvalidations(using: MemoryInvalidationStore(defaults: defaults))
                try await engine.purgeMemory(owner: "source-owner", token: "")
                let late = try await assertLateUsageAfterPurge(
                    engine, id: initial.id, receipt: old, runId: retry.run?.id
                )
                beforeRelease = cancelRetry
                    ? try await engine.cancel(conversationId: initial.id, runId: retry.run!.id, token: "")
                    : late
            }
            assertPurged(result)
            XCTAssertEqual(result.run?.id, retry.run?.id)
            XCTAssertEqual(result.run?.status, cancelRetry ? "cancelled" : "waiting_inference")
            XCTAssertEqual(result.run?.budget?.actual.tokens, 10)
            XCTAssertEqual(result.run?.budgetRootId, initial.run?.budgetRootId)
            if cancelRetry {
                XCTAssertEqual(result.messages, beforeRelease.messages)
                XCTAssertEqual(result.revision, beforeRelease.revision)
            } else {
                result = try await completeBudgetedRetry(engine, conversation: result)
            }
            XCTAssertFalse(result.messages.contains { $0.text == old.content || $0.toolCallId == "stale-plan" })
            try await assertBudgetedRecovery(result, old: old, notesFile: notesFile,
                                             defaults: defaults, snapshot: initial.memory)
            XCTAssertEqual(fixture.requestCount, 1)
        }
    }

    private func completeBudgetedRetry(_ engine: AskLocalEngine,
                                       conversation: AskConversation) async throws -> AskConversation {
        let completion = try AskInferenceResult(
            runId: XCTUnwrap(conversation.run?.id), deviceId: device,
            inferenceId: XCTUnwrap(conversation.run?.inference?.id), content: "Fresh answer",
            usage: .init(promptTokens: 10, completionTokens: 10, totalTokens: 20)
        )
        let result = try await engine.inferenceResult(conversationId: conversation.id, request: completion, token: "")
        XCTAssertEqual(result.run?.status, "completed")
        XCTAssertEqual(result.run?.budget?.actual.tokens, 30)
        return result
    }

    private func staleReceipt(_ run: AskRun) throws -> AskInferenceResult {
        try .init(runId: run.id, deviceId: device, inferenceId: XCTUnwrap(run.inference?.id),
                  content: "Stale answer", toolCalls: [plan("stale-plan", status: "completed")],
                  usage: .init(promptTokens: 5, completionTokens: 5, totalTokens: 10))
    }

    private func assertLateUsageAfterPurge(_ engine: AskLocalEngine, id: String,
                                           receipt: AskInferenceResult, runId: String?) async throws -> AskConversation {
        let purged = try await engine.conversation(id: id, token: "")
        let late = try await engine.inferenceResult(conversationId: id, request: receipt, token: "")
        assertPurged(late)
        XCTAssertEqual(late.revision, purged.revision)
        XCTAssertEqual(late.messages, purged.messages)
        XCTAssertEqual(late.run?.id, runId)
        XCTAssertEqual(late.run?.status, "running")
        XCTAssertEqual(late.run?.pending, purged.run?.pending)
        XCTAssertEqual(late.run?.plan, purged.run?.plan)
        XCTAssertEqual(late.run?.budget?.actual.tokens, 10)
        XCTAssertEqual(late.run?.budget?.occupied, purged.run?.budget?.occupied)
        let duplicate = try await engine.inferenceResult(conversationId: id, request: receipt, token: "")
        XCTAssertEqual(duplicate, late)
        return late
    }

    private func assertBudgetedRecovery(_ result: AskConversation, old: AskInferenceResult,
                                        notesFile: URL, defaults: UserDefaults, snapshot: AskMemory?) async throws {
        try await assertPersisted(result)
        let reopened = AskLocalEngine(directory: directory, budgetEnabled: true)
        let duplicate = try await reopened.inferenceResult(conversationId: result.id, request: old, token: "")
        XCTAssertEqual(duplicate.run?.budget, result.run?.budget)
        assertPurged(duplicate)
        let tombstones = try JSONDecoder().decode([String: [AskMemoryNote]].self, from: Data(contentsOf: notesFile))
        XCTAssertNotNil(tombstones["source-owner"]?.first?.deletedAt)
        XCTAssertEqual(tombstones["source-owner"]?.first?.text, "")
        let invalidations = MemoryInvalidationStore(defaults: defaults)
        XCTAssertNotNil(invalidations.cutoff(owner: "source-owner"))
        XCTAssertNil(try XCTUnwrap(snapshot).usable(owner: "source-owner", invalidations: invalidations))
        let journal = try AskBudgetStore(directory: directory).update(
            conversation: result.id, root: XCTUnwrap(result.run?.budgetRootId)
        ) { _ in }
        XCTAssertEqual(journal.reservations[old.inferenceId]?.actual.tokens, 10)
        XCTAssertEqual(journal.reservations[old.inferenceId]?.state, "pending")
        XCTAssertEqual(journal.reservations[old.inferenceId]?.identity?.owner, AskRoutedAPI.localOwner)
    }
}

/// Each URL has its own gate, so parallel tests cannot release one another's
/// fetch. A released gate also completes unexpected retries instead of hanging.
private final class SuspendedLocalFetch: @unchecked Sendable {
    let started = XCTestExpectation(description: "web_search suspended")
    let url = URL(string: "https://example.com/\(UUID().uuidString)")!
    let status: Int
    private let lock = NSLock()
    private var requests: [SuspendedLocalFetchProtocol] = []
    private var released = false
    private var count = 0
    private let session: URLSession

    init(status: Int = 200) {
        self.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedLocalFetchProtocol.self]
        session = URLSession(configuration: configuration)
        SuspendedLocalFetchProtocol.register(self)
    }

    var tools: AskLocalWebTools {
        AskLocalWebTools(session: session, searchProvider: { .init(provider: .tavily, apiKey: "fixture") },
                         resolve: { _ in ["93.184.216.34"] }, searchEndpoints: [.tavily: url.absoluteString])
    }
    var requestCount: Int { lock.withLock { count } }

    func receive(_ request: SuspendedLocalFetchProtocol) {
        let shouldComplete = lock.withLock {
            count += 1
            if released { return true }
            requests.append(request)
            return false
        }
        started.fulfill()
        if shouldComplete { complete(request) }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = requests
            requests.removeAll()
            return pending
        }
        for request in pending { complete(request) }
    }

    private func complete(_ request: SuspendedLocalFetchProtocol) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = #"""
        {"results":[{"title":"Fixture","url":"https://example.com","content":"Fetched page"}]}
        """#
        request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }

    func close() {
        release()
        session.invalidateAndCancel()
        SuspendedLocalFetchProtocol.unregister(self)
    }
}

private final class SuspendedLocalFetchProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [URL: SuspendedLocalFetch] = [:]

    static func register(_ fixture: SuspendedLocalFetch) { lock.withLock { fixtures[fixture.url] = fixture } }
    static func unregister(_ fixture: SuspendedLocalFetch) { lock.withLock { fixtures[fixture.url] = nil } }
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ request.url.flatMap { Self.fixtures[$0] } }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        fixture.receive(self)
    }
    override func stopLoading() {}
}
