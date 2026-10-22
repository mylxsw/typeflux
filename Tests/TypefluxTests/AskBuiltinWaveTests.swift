import Foundation
@testable import Typeflux
import XCTest

final class AskBuiltinWaveTests: XCTestCase {
    private func engine(_ host: WaveBuiltinHost, budget: Int64? = nil) -> AskLocalEngine {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wave-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var limits = AskBudgetResources.standard
        limits.webRequests = budget ?? limits.webRequests
        return AskLocalEngine(directory: directory, budgetEnabled: budget != nil, budgetLimits: limits, builtinTools: host)
    }

    private func initial(_ engine: AskLocalEngine, approval: Bool = false) async throws -> AskConversation {
        var request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Question", tools: [], modelRef: "custom:test")
        request.clientToolApproval = approval
        return try await engine.send(conversationId: "wave", request: request, token: "")
    }

    private func receipt(_ c: AskConversation, names: [String]) throws -> AskInferenceResult {
        .init(runId: try XCTUnwrap(c.run?.id), deviceId: "device", inferenceId: try XCTUnwrap(c.run?.inference?.id), content: "",
              toolCalls: names.enumerated().map { .init(id: String($0.offset), function: .init(name: $0.element, arguments: "{}")) })
    }

    func testSevenReadsOverlapInThreeOrderedWaves() async throws {
        let host = WaveBuiltinHost(failingIDs: ["1"])
        let engine = engine(host)
        let c = try await initial(engine)
        let input = try receipt(c, names: Array(repeating: "web_search", count: 7))
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for base in stride(from: 0, to: 7, by: 3) {
            let width = min(3, 7 - base)
            var ids = Set<String>()
            for _ in 0..<width { let event = await events.next(); ids.insert(try XCTUnwrap(event)) }
            XCTAssertEqual(ids, Set((base..<(base + width)).map(String.init)))
            XCTAssertEqual(host.ids.count, base + width)
            for index in (base..<(base + width)).reversed() { host.release(String(index)) }
        }
        let result = try await task.value
        XCTAssertEqual(host.peak, 3)
        XCTAssertEqual(host.active, 0)
        XCTAssertEqual(result.messages.filter { $0.role == "tool" }.compactMap(\.toolCallId), (0..<7).map(String.init))
        XCTAssertEqual(result.run?.status, "waiting_inference")
        XCTAssertEqual(result.messages.first { $0.toolCallId == "1" }?.isError, true)
        XCTAssertEqual(result.messages.first { $0.toolCallId == "2" }?.isError, false)
    }

    func testPlanAndUnclassifiedHostAreSerialBarriers() async throws {
        for independent in [true, false] {
            let host = WaveBuiltinHost(independent: independent)
            let engine = engine(host)
            let c = try await initial(engine)
            let input = try receipt(c, names: ["web_search", "update_plan", "web_search"])
            let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
            var events = host.events.makeAsyncIterator()
            for index in 0..<3 {
                let started = await events.next()
                XCTAssertEqual(started, String(index))
                XCTAssertEqual(host.ids.count, index + 1)
                host.release(String(index))
            }
            _ = try await task.value
            XCTAssertEqual(host.peak, 1)
        }
    }

    func testApprovalNeverAuthorizesAdjacentRead() async throws {
        let host = WaveBuiltinHost()
        let engine = engine(host)
        let c = try await initial(engine, approval: true)
        let input = try receipt(c, names: ["web_search", "web_search"])
        let waiting = try await engine.inferenceResult(conversationId: c.id, request: input, token: "")
        XCTAssertTrue(host.ids.isEmpty)
        let task = Task { try await engine.result(conversationId: c.id, request: .init(approveExecution: true,
            runId: input.runId, deviceId: "device", toolCallId: "0", content: "", isError: false), token: "") }
        var events = host.events.makeAsyncIterator()
        let started = await events.next()
        XCTAssertEqual(started, "0")
        XCTAssertEqual(host.ids, ["0"])
        host.release("0")
        let result = try await task.value
        XCTAssertEqual(waiting.run?.status, "waiting_tool")
        XCTAssertEqual(result.run?.status, "waiting_tool")
        XCTAssertEqual(result.run?.pending.first?.id, "1")
        XCTAssertEqual(host.ids, ["0"])
    }

    func testBudgetShortageAtEachAdmissionSlotLaunchesNothing() async throws {
        for slots in 0..<3 {
            let host = WaveBuiltinHost()
            let engine = engine(host, budget: Int64(slots))
            let c = try await initial(engine)
            let result = try await engine.inferenceResult(conversationId: c.id,
                request: receipt(c, names: Array(repeating: "web_search", count: 3)), token: "")
            XCTAssertTrue(host.ids.isEmpty)
            XCTAssertEqual(result.run?.stopReason, "web_requests")
            XCTAssertFalse(result.run?.budget?.events?.contains { $0.kind == "web_search" && ["pending", "reserved"].contains($0.state) } == true)
        }
    }

    func testCancellationDrainsEveryChildAndSettlesOriginalBudget() async throws {
        let host = WaveBuiltinHost()
        let engine = engine(host, budget: 3)
        let c = try await initial(engine)
        let input = try receipt(c, names: Array(repeating: "web_search", count: 3))
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for _ in 0..<3 { _ = await events.next() }
        _ = try await engine.cancel(conversationId: c.id, runId: input.runId, token: "")
        let result = try await task.value
        XCTAssertEqual(host.active, 0)
        XCTAssertEqual(result.run?.status, "cancelled")
        XCTAssertEqual(result.run?.budget?.events?.filter { $0.kind == "web_search" && $0.state == "settled" }.count, 3)
        XCTAssertFalse(result.messages.contains { $0.text.hasPrefix("result-") })
    }
    func testPurgeDuringWavePreservesLatestMemoryAndOrderedResults() async throws {
        let host = WaveBuiltinHost()
        let engine = engine(host, budget: 6)
        var request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Question", tools: [], modelRef: "custom:test")
        request.memory = AskMemory(global: "private memory")
        let c = try await engine.send(conversationId: "wave", request: request, token: "")
        let input = try receipt(c, names: Array(repeating: "web_search", count: 3))
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for _ in 0..<3 { _ = await events.next() }
        try await engine.purgeMemory(token: "")
        for id in ["2", "1", "0"] { host.release(id) }
        let result = try await task.value
        XCTAssertNil(result.memory)
        XCTAssertEqual(result.messages.filter { $0.role == "tool" }.compactMap(\.toolCallId), ["0", "1", "2"])
        XCTAssertEqual(result.run?.status, "waiting_inference")
    }

    func testReplacementWinsOverUncooperativeLateWaveAndOriginalRootSettles() async throws {
        let host = WaveBuiltinHost(ignoreCancellation: true)
        let engine = engine(host, budget: 3)
        let c = try await initial(engine)
        let input = try receipt(c, names: Array(repeating: "web_search", count: 3))
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for _ in 0..<3 { _ = await events.next() }
        _ = try await engine.cancel(conversationId: c.id, runId: input.runId, token: "")
        let replacement = try await initial(engine)
        for id in ["2", "1", "0"] { host.release(id) }
        let result = try await task.value
        XCTAssertEqual(result.run?.id, replacement.run?.id)
        XCTAssertFalse(result.messages.contains { $0.text.hasPrefix("result-") })
        XCTAssertEqual(result.run?.budget?.actual.webRequests, 0)
        let budgets = await engine.budgetStore
        let old = try budgets.update(conversation: c.id, root: c.run!.budgetRootId!, initial: nil) { _ in }
        XCTAssertEqual(old.reservations.values.filter { $0.kind == "web_search" && $0.state == "settled" }.count, 3)
        XCTAssertEqual(host.active, 0)
    }

    func testDeletionDrainsChildrenWithoutRestoringPublicContent() async throws {
        let host = WaveBuiltinHost()
        let engine = engine(host, budget: 3)
        let c = try await initial(engine)
        let input = try receipt(c, names: Array(repeating: "web_search", count: 3))
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for _ in 0..<3 { _ = await events.next() }
        try await engine.delete(conversationId: c.id, token: "")
        do { _ = try await task.value; XCTFail("Deleted wave cannot publish results") } catch {}
        XCTAssertEqual(host.active, 0)
        do { _ = try await engine.conversation(id: c.id, token: ""); XCTFail("Deleted content must stay unreadable") } catch {}
        let budgets = await engine.budgetStore
        let old = try budgets.update(conversation: c.id, root: c.run!.budgetRootId!, initial: nil) { _ in }
        XCTAssertEqual(old.reservations.values.filter { $0.kind == "web_search" && $0.state == "settled" }.count, 3)
    }

    func testSessionTaskCancellationDrainsOriginalWaveAndStopsFurtherAdmission() async throws {
        let host = WaveBuiltinHost(ignoreCancellation: true)
        let engine = engine(host, budget: 7)
        let c = try await initial(engine)
        let input = try receipt(c, names: Array(repeating: "web_search", count: 7))
        // Account/session reset cancels the owned operation task. An
        // uncooperative host can still finish, but cannot launch another wave.
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for _ in 0..<3 { _ = await events.next() }
        task.cancel()
        for id in ["2", "1", "0"] { host.release(id) }
        do { _ = try await task.value; XCTFail("Session cancellation must remain visible") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(host.active, 0)
        XCTAssertEqual(host.ids.count, 3)
        let current = try await engine.conversation(id: c.id, token: "")
        XCTAssertNil(current.run?.inference)
        XCTAssertEqual(current.run?.pending.count, 4)
        XCTAssertEqual(current.run?.budget?.events?.filter { $0.kind == "web_search" && $0.state == "settled" }.count, 3)
    }

    func testLastLegacyAllowanceDoesNotAuthorizeSiblingTransport() async throws {
        let host = WaveBuiltinHost()
        let engine = engine(host)
        var c = try await initial(engine)
        var events = host.events.makeAsyncIterator()
        var base = 0
        for count in [7, 7, 3] {
            var input = try receipt(c, names: Array(repeating: "web_search", count: count))
            for index in input.toolCalls.indices { input.toolCalls[index].id = String(base + index) }
            let id = c.id
            let task = Task { try await engine.inferenceResult(conversationId: id, request: input, token: "") }
            let permitted = min(count, AskLocalEngine.maxBuiltinCalls - base)
            for _ in 0..<permitted {
                let event = await events.next()
                let started = try XCTUnwrap(event)
                host.release(started)
            }
            c = try await task.value
            base += count
        }
        XCTAssertEqual(host.ids.count, AskLocalEngine.maxBuiltinCalls)
        XCTAssertEqual(host.active, 0)
        XCTAssertEqual(c.messages.first { $0.toolCallId == "16" }?.isError, true)
        XCTAssertFalse(host.ids.contains("16"))
    }

    func testMissingOriginalJournalCannotBeRecreatedByLateSettlement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wave-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = WaveBuiltinHost()
        let engine = AskLocalEngine(directory: directory, budgetEnabled: true, builtinTools: host)
        let c = try await initial(engine)
        let input = try receipt(c, names: Array(repeating: "web_search", count: 3))
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for _ in 0..<3 { _ = await events.next() }
        let file = directory.appendingPathComponent("Budgets").appendingPathComponent(c.id)
            .appendingPathComponent(c.run!.budgetRootId! + ".json")
        try FileManager.default.removeItem(at: file)
        for id in ["2", "1", "0"] { host.release(id) }
        do { _ = try await task.value; XCTFail("Missing accounting must remain an error") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertEqual(host.ids.count, 3)
        XCTAssertEqual(host.active, 0)
    }

}

private final class WaveBuiltinHost: AskBuiltinToolHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var cancelled = Set<String>()
    private var started: [String] = []
    private var inFlight = 0
    private var maximum = 0
    private let independent: Bool
    private let ignoreCancellation: Bool
    private let failingIDs: Set<String>
    let events: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    init(independent: Bool = true, ignoreCancellation: Bool = false, failingIDs: Set<String> = []) {
        self.failingIDs = failingIDs
        self.ignoreCancellation = ignoreCancellation
        self.independent = independent
        (events, continuation) = AsyncStream.makeStream()
    }
    var ids: [String] { lock.withLock { started } }
    var peak: Int { lock.withLock { maximum } }
    var active: Int { lock.withLock { inFlight } }
    func definitions() -> [AskToolDefinition] {
        [AskLocalEngine.planTool, .init(name: "web_search", description: "Fixture", parameters: .init(data: Data("{}".utf8)))]
    }
    func executionClassification(for definition: AskToolDefinition) -> AskBuiltinExecutionClass {
        independent && definition.name == "web_search" ? .independentWebRead : .serial
    }
    func release(_ id: String) {
        lock.withLock { held.removeValue(forKey: id) }?.resume()
    }
    func execute(_ input: AskBuiltinToolInput) async -> AskBuiltinToolOutput {
        let id = input.call.id
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                let cancelled = lock.withLock {
                    started.append(id); inFlight += 1; maximum = max(maximum, inFlight)
                    if self.cancelled.contains(id) { return true }
                    held[id] = pending
                    return false
                }
                continuation.yield(id)
                if cancelled { pending.resume() }
            }
        } onCancel: {
            guard !self.ignoreCancellation else { return }
            let pending = self.lock.withLock {
                self.cancelled.insert(id)
                return self.held.removeValue(forKey: id)
            }
            pending?.resume()
        }
        lock.withLock { inFlight -= 1 }
        return .init(text: "result-" + id, isError: Task.isCancelled || failingIDs.contains(id))
    }
}

extension AskBuiltinWaveTests {
    func testStockHostWithOfflineHTTPTransportAndControlledLatency() async throws {
        for parallel in [false, true] {
            let fixture = WaveHTTPFixture()
            WaveHTTPProtocol.install(fixture)
            defer { WaveHTTPProtocol.install(nil) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WaveHTTPProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let web = AskLocalWebTools(session: session,
                searchProvider: { .init(provider: .tavily, apiKey: "offline-fixture") },
                searchEndpoints: [.tavily: "https://fixture.invalid/search"])
            let stock = DefaultAskBuiltinToolHost(webTools: web)
            let host: any AskBuiltinToolHosting = parallel ? stock : SerialStockBuiltinHost(host: stock)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stock-wave-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = AskLocalEngine(directory: directory, budgetEnabled: true, builtinTools: host)
            let c = try await initial(engine)
            var input = try receipt(c, names: Array(repeating: "web_search", count: 6))
            for index in input.toolCalls.indices { input.toolCalls[index].function.arguments = #"{"query":"fixture"}"# }
            let start = Date()
            let result = try await engine.inferenceResult(conversationId: c.id, request: input, token: "")
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(fixture.completed, 6)
            XCTAssertEqual(fixture.active, 0)
            XCTAssertEqual(fixture.peak, parallel ? 3 : 1)
            XCTAssertEqual(result.messages.filter { $0.role == "tool" }.count, 6)
            XCTAssertEqual(result.run?.budget?.actual.webRequests, 6)
            print("WAVE_LATENCY stock_swift parallel=\(parallel) injected_delay_ms=40 requests=6 peak=\(fixture.peak) completed=\(fixture.completed) web_quota=\(result.run?.budget?.actual.webRequests ?? -1) elapsed_ms=\(elapsed * 1000)")
        }
    }
}

private struct SerialStockBuiltinHost: AskBuiltinToolHosting {
    let host: DefaultAskBuiltinToolHost
    func definitions() -> [AskToolDefinition] { host.definitions() }
    func execute(_ input: AskBuiltinToolInput) async -> AskBuiltinToolOutput { await host.execute(input) }
}

private final class WaveHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = Set<ObjectIdentifier>()
    private var maximum = 0
    private var finished = 0
    var active: Int { lock.withLock { requests.count } }
    var peak: Int { lock.withLock { maximum } }
    var completed: Int { lock.withLock { finished } }
    func begin(_ request: URLProtocol) {
        lock.withLock { requests.insert(ObjectIdentifier(request)); maximum = max(maximum, requests.count) }
    }
    func end(_ request: URLProtocol, completed: Bool) -> Bool {
        lock.withLock {
            guard requests.remove(ObjectIdentifier(request)) != nil else { return false }
            if completed { finished += 1 }
            return true
        }
    }
}

private final class WaveHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: WaveHTTPFixture?
    private var owned: WaveHTTPFixture?
    static func install(_ fixture: WaveHTTPFixture?) { lock.withLock { self.fixture = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixture }) else { return }
        owned = fixture
        fixture.begin(self)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(40)) { [self] in
            guard fixture.end(self, completed: true), let url = request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"results":[{"title":"Fixture","url":"https://example.com","content":"Evidence"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { if let owned { _ = owned.end(self, completed: false) } }
}

extension AskBuiltinWaveTests {
    func testCompletedWaveIsNotReexecutedAfterSnapshotWriteFailure() async throws {
        let host = WaveBuiltinHost()
        let snapshots = WaveFailingSnapshots()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wave-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AskLocalEngine(directory: directory, budgetEnabled: true, builtinTools: host, snapshotStore: snapshots)
        let c = try await initial(engine)
        let input = try receipt(c, names: Array(repeating: "web_search", count: 3))
        let task = Task { try await engine.inferenceResult(conversationId: c.id, request: input, token: "") }
        var events = host.events.makeAsyncIterator()
        for _ in 0..<3 { _ = await events.next() }
        snapshots.failCompletedWave = true
        for id in ["2", "1", "0"] { host.release(id) }
        do { _ = try await task.value; XCTFail("Expected failed result checkpoint") } catch {}
        snapshots.failCompletedWave = false
        let replay = try await engine.inferenceResult(conversationId: c.id, request: input, token: "")
        XCTAssertEqual(host.ids.count, 3)
        XCTAssertEqual(host.active, 0)
        XCTAssertEqual(replay.messages.filter { $0.role == "tool" }.count, 3)
        XCTAssertTrue(replay.run?.pending.isEmpty == true)
        XCTAssertEqual(replay.run?.recovery?.state, "unknown_outcome")
        XCTAssertEqual(replay.run?.budget?.events?.filter { $0.kind == "web_search" && $0.state == "settled" }.count, 3)
    }
}

private final class WaveFailingSnapshots: AskLocalSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: Data] = [:]
    private var failing = false
    var failCompletedWave: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func forEachSnapshot(_ consume: (Data) -> Void) { for data in lock.withLock({ Array(snapshots.values) }) { consume(data) } }
    func writeSnapshot(_ data: Data, id: String) throws {
        try lock.withLock {
            if failing, let record = try? AskLocalRecord.decodeSnapshot(data),
               record.conversation.messages.contains(where: { $0.text.hasPrefix("result-") }) {
                throw CocoaError(.fileWriteUnknown)
            }
            snapshots[id] = data
        }
    }
    func removeSnapshot(id: String) throws { lock.withLock { _ = snapshots.removeValue(forKey: id) } }
}
