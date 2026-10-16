import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

// Pure IPC envelope; no encoder or decoder is invoked.
private let toolBatchJPEG = Data([255, 216, 255, 192, 0, 11, 8, 0, 2, 0, 2, 1, 1, 17, 0,
    255, 218, 0, 8, 1, 1, 0, 0, 63, 0, 0, 255, 217])
private let toolBatchURL = "data:image/jpeg;base64," + toolBatchJPEG.base64EncodedString()
private final class ToolBatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, reads = 0
    var counts: [Int] { lock.withLock { [runs, reads] } }
    func run() -> Int { lock.withLock { runs += 1; return runs } }
    func read() -> Int { lock.withLock { reads += 1; return reads } }
}
private final class ToolBatchGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private actor ToolBatchCustomNormalizer {
    private(set) var calls = 0
    func normalize(_ data: Data, _ type: MediaImageType) -> String { calls += 1; return toolBatchURL }
}

@Suite("Tool projection original batch authority", .serialized)
@MainActor struct ToolBatchAuthorityTests {
    private var blocks: [MCPContentBlock] {
        [1, 2].map { .init(type: "image", data: Data([UInt8($0)]).base64EncodedString(), mimeType: "image/png") }
    }
    private func worker(_ state: ToolBatchState, refuseFirst: Bool = false, held: ToolBatchGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            let number = state.run(); held?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            var response = MediaResponse(id: request.id)
            if refuseFirst && number == 1 { response.failure = .unreadable }
            else {
                response.items = [.init(image: toolBatchURL)]
                response.normalization = request.normalization
            }
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func history(_ raw: [JSONValue]) -> [AskMessage] {
        raw.enumerated().map { i, block in
            .init(id: String(i), role: "tool", text: "completed", image: "old-legacy", createdAt: Date(),
                  harness: .init(version: 1, outcome: .init(status: "ok", content: [block])))
        }
    }
    private func objects(_ values: [JSONValue]?) -> [NSDictionary] {
        (values ?? []).map { AskTypedContent.object($0) as NSDictionary }
    }
    private func consume(_ kind: String, normalizer: AskToolImageNormalizer,
                         readImage: AskTypedContent.ImageReader = { AskTypedContent.imageInput(AskTypedContent.object($0)) }) async -> [AskExecutionOutcome] {
        let raw = blocks.map(\.raw)
        if kind == "output" {
            let value = await AskTypedContent.output(from: .init(content: blocks, isError: false), normalizer: normalizer, readImage: readImage)
            if value.outcome?.projectionWithheld == true { #expect(value.image == nil && value.isError) }
            return [value.outcome!]
        }
        if kind == "history" {
            let values = await AskTypedContent.prepareHistory(history(raw), normalizer: normalizer, readImage: readImage)
            if values.contains(where: { $0.harness?.outcome?.projectionWithheld == true }) {
                #expect(values.allSatisfy { $0.image == nil && $0.resultImages.isEmpty && $0.isError == true })
            }
            return values.compactMap { $0.harness?.outcome }
        }
        return [await AskTypedContent.prepare(.init(status: "ok", content: raw), normalizer: normalizer, readImage: readImage)]
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test(arguments: ["prepare", "output", "history"])
    func recoveryBetweenCompletedImagesRevokesWholeProjection(_ kind: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolBatchState(), worker = worker(state), gate = ToolBatchGate()
        defer { gate.release() }
        let normalizer = AskToolImageNormalizer(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let task = Task { await consume(kind, normalizer: normalizer, readImage: { raw in
            if state.read() == 2 { gate.wait() }
            return AskTypedContent.imageInput(AskTypedContent.object(raw))
        }) }
        await wait { state.counts == [1, 2] }
        #expect(worker.activeCount == 0) // First image finished; history has crossed a message boundary.
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release()
        let values = await task.value
        #expect(values.allSatisfy { $0.preparedImages.isEmpty && $0.projectionWithheld == true && $0.safeStatus == .ok })
        #expect(values.flatMap { $0.content ?? [] } == blocks.map(\.raw) && state.counts == [1, 2])
        let fresh = await consume(kind, normalizer: normalizer)
        #expect(fresh.reduce(0) { $0 + AskTypedContent.project($1).images.count } == 2 && state.counts[0] == 3)
        await registry.shutdown()
    }

    @Test(arguments: ["prepare", "output", "history"])
    func preReadyAndPrecancelledOuterEntriesDoNotReadOrReplay(_ kind: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolBatchState(), worker = worker(state), normalizer = AskToolImageNormalizer(worker: worker)
        let unavailable = await consume(kind, normalizer: normalizer, readImage: { raw in
            _ = state.read(); return AskTypedContent.imageInput(AskTypedContent.object(raw))
        })
        #expect(unavailable.allSatisfy { $0.projectionWithheld == true } && state.counts == [0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(state.counts == [0, 0])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await consume(kind, normalizer: normalizer)
        }
        #expect(await task.value.allSatisfy { $0.preparedImages.isEmpty && $0.projectionWithheld == true })
        #expect(state.counts == [0, 0])
        let withheld = await AskTypedContent.prepare(unavailable[0], normalizer: normalizer)
        #expect(withheld.projectionWithheld == true && state.counts[0] == 0)
        let fresh = await consume(kind, normalizer: normalizer)
        #expect(fresh.reduce(0) { $0 + AskTypedContent.project($1).images.count } == 2)
        await registry.shutdown()
    }

    @Test func sandboxCandidatesRetainOneStampAndPrivateFilesAfterRecovery() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolBatchState(), worker = worker(state, refuseFirst: true), gate = ToolBatchGate()
        defer { gate.release() }
        let normalizer = AskToolImageNormalizer(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let workspace = try AskSecureDirectory.openRoot(root.appendingPathComponent("program-output"))
        try workspace.createFile("one.png", data: Data([1])); try workspace.createFile("two.jpg", data: Data([2]))
        let task = Task { await AskCodeSandbox.firstImage([("one.png", 1), ("two.jpg", 1)], workspace: workspace,
            normalizer: normalizer, readFile: { workspace, path, limit in
                if state.read() == 2 { gate.wait() }
                return try workspace.readFile(path, limit: limit)
            }) }
        await wait { state.counts == [1, 2] }; #expect(worker.activeCount == 0)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release()
        let result = await task.value
        #expect(result.url == nil && result.incomplete && state.counts == [1, 2])
        #expect(try workspace.readFile("one.png", limit: 10) == Data([1]))
        #expect(try workspace.readFile("two.jpg", limit: 10) == Data([2]))
        let fresh = await AskCodeSandbox.firstImage([("two.jpg", 1)], workspace: workspace, normalizer: normalizer)
        #expect(fresh.url == toolBatchURL && !fresh.incomplete && state.counts[0] == 2)
        let empty = await AskCodeSandbox.firstImage([], workspace: workspace, normalizer: normalizer)
        #expect(empty.url == nil && !empty.incomplete)
        await registry.shutdown()
    }

    @Test func cancellationDuringParsingCannotPublishEarlierProofAndDoesNotRepeatProducer() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolBatchState(), worker = worker(state), gate = ToolBatchGate()
        defer { gate.release() }
        let normalizer = AskToolImageNormalizer(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let task = Task { await consume("output", normalizer: normalizer, readImage: { raw in
            if state.read() == 2 { gate.wait() }
            return AskTypedContent.imageInput(AskTypedContent.object(raw))
        }) }
        await wait { state.counts == [1, 2] }; task.cancel(); gate.release()
        let result = await task.value
        #expect(result[0].content == blocks.map(\.raw) && result[0].preparedImages.isEmpty && result[0].projectionWithheld == true)
        #expect(state.counts == [1, 2] && worker.activeCount == 0)
        // Serialization never turns the temporary proof into an authority grant.
        var receipt = AskToolResultRequest(runId: "r", deviceId: "d", toolCallId: "c", content: "ran", isError: true,
            harness: .init(version: 1, outcome: result[0]))
        let encoded = try JSONEncoder().encode(receipt)
        receipt = try JSONDecoder().decode(AskToolResultRequest.self, from: encoded)
        #expect(objects(receipt.harness?.outcome?.content) == objects(blocks.map(\.raw)))
        #expect(receipt.forPeer(AskTypedContent.advertisement, enabled: [.typedContent]).image == nil)
        #expect(receipt.message(step: 1, now: Date()).retainedResultImages.isEmpty)
        await registry.shutdown()
    }

    @Test func cancellationDuringNativeWorkRetainsSlotsThroughActualReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolBatchState(), gate = ToolBatchGate(), worker = worker(state, held: gate)
        defer { gate.release() }
        let normalizer = AskToolImageNormalizer(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let a = Task { await consume("prepare", normalizer: normalizer) }
        let b = Task { await consume("history", normalizer: normalizer) }
        await wait { state.counts[0] == 2 }; a.cancel(); b.cancel()
        #expect(worker.activeCount == 2)
        do { _ = try await normalizer.normalize(Data([1]), type: .png); Issue.record("Occupied slots released early") } catch {}
        gate.release()
        let first = await a.value, second = await b.value
        #expect((first + second).allSatisfy { $0.preparedImages.isEmpty && $0.projectionWithheld == true })
        #expect(worker.activeCount == 0 && state.counts[0] == 2)
        await registry.shutdown()
    }

    @Test func customActorAndHistoryWindowRemainIndependentOfNativeReadiness() async throws {
        let state = ToolBatchState(), worker = worker(state), normalizer = AskToolImageNormalizer(worker: worker)
        let custom = ToolBatchCustomNormalizer(), raw = blocks[0].raw
        let messages = history(Array(repeating: raw, count: 15))
        let prepared = await AskTypedContent.prepareHistory(messages, normalize: { await custom.normalize($0, $1) }, normalizer: normalizer)
        #expect(await custom.calls == 8)
        #expect(prepared.filter { !$0.resultImages.isEmpty }.count == 8 && prepared[0].resultImages.isEmpty)
        #expect(prepared[0].retainedResultImages.count == 1 && prepared.allSatisfy { $0.harness?.outcome?.content == [raw] })
        #expect(state.counts == [0, 0])
        let structured = await AskTypedContent.output(from: .init(content: [], isError: false,
            structuredContent: AskTypedContent.json(["count": 1])), normalizer: normalizer)
        #expect(!structured.isError && structured.content.contains("Structured content") && structured.outcome?.projectionWithheld != true)
    }

    @Test func malformedProofBoundsAndRawReceiptFallbackStayIntact() async throws {
        let raw = blocks[0].raw
        let invalid = await AskTypedContent.prepare(.init(status: "ok", content: [raw])) { _, _ in "untrusted" }
        #expect(invalid.content == [raw] && invalid.preparedImages.isEmpty && invalid.projectionWithheld != true)
        let many = await AskTypedContent.prepare(.init(status: "ok", content: Array(repeating: raw, count: 10))) { _, _ in toolBatchURL }
        #expect(AskTypedContent.project(many).images.count == 4 && many.content?.count == 10)
        let malformed = AskTypedContent.json(["type": "image", "data": "@@@", "mimeType": "image/png"])
        let refusal = await AskTypedContent.prepare(.init(status: "ok", content: [malformed])) { _, _ in
            Issue.record("Malformed input normalized"); return toolBatchURL
        }
        #expect(refusal.preparedImages.isEmpty && AskTypedContent.project(refusal).incomplete)
        let big = "data:image/jpeg;base64," + (Data(toolBatchJPEG.dropLast(2)) + Data(repeating: 0, count: 800000) + Data(toolBatchJPEG.suffix(2))).base64EncodedString()
        #expect(AskToolImageNormalizer.valid(big))
        let bounded = await AskTypedContent.prepare(.init(status: "ok", content: blocks.map(\.raw))) { _, _ in big }
        #expect(bounded.preparedImages.count == 1 && AskTypedContent.project(bounded).incomplete)
        let encoded = try JSONEncoder().encode(many)
        let reopened = try JSONDecoder().decode(AskExecutionOutcome.self, from: encoded)
        #expect(reopened.preparedImages.isEmpty && objects(reopened.content) == objects(many.content))
    }

    @Test func sandboxPreReadyAndCustomCandidateBoundsDoNotGrantNativeWork() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolBatchState(), worker = worker(state), normalizer = AskToolImageNormalizer(worker: worker)
        let workspace = try AskSecureDirectory.openRoot(root.appendingPathComponent("outputs"))
        let files = (0..<5).map { (name: "\($0).png", size: 1) }
        for file in files { try workspace.createFile(file.name, data: Data([1])) }
        let unavailable = await AskCodeSandbox.firstImage(files, workspace: workspace, normalizer: normalizer,
            readFile: { workspace, path, limit in _ = state.read(); return try workspace.readFile(path, limit: limit) })
        #expect(unavailable.url == nil && unavailable.incomplete && state.counts == [0, 0])
        let custom = await AskCodeSandbox.firstImage(files, workspace: workspace,
            normalize: { _, _ in throw MediaFailure.unavailable }, normalizer: normalizer,
            readFile: { workspace, path, limit in _ = state.read(); return try workspace.readFile(path, limit: limit) })
        #expect(custom.url == nil && custom.incomplete && state.counts == [0, 4])
        let success = await AskCodeSandbox.firstImage(files, workspace: workspace, normalize: { _, _ in toolBatchURL }, normalizer: normalizer)
        #expect(success.url == toolBatchURL && !success.incomplete && worker.activeCount == 0)
    }
}
