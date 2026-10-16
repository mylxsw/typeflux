import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class ToolModelState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, replies = 0
    var counts: [Int] { lock.withLock { [runs, replies] } }
    func run() { lock.withLock { runs += 1 } }
    func reply() { lock.withLock { replies += 1 } }
}
private final class ToolModelGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, entered = 0
    var count: Int { condition.withLock { entered } }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        entered += 1
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private actor ToolModelDecoder {
    private(set) var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    var waiting: Bool { waiter != nil }
    func release() { waiter?.resume(); waiter = nil }
    func decode(_ bytes: Data, hold: Bool = false) async -> AskFilePreviewPDF.Result {
        calls += 1
        if hold { await withCheckedContinuation { waiter = $0 } }
        return .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
}

@Suite("Tool image model original native authority", .exclusiveUIState)
@MainActor struct ToolImageModelAuthorityTests {
    private let source = "data:image/png;base64,AQID"
    private let newer = "data:image/png;base64,BAUG"
    private func worker(_ state: ToolModelState, gate: ToolModelGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw MediaFailure.unavailable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(repeating: 128, count: 16))
            var response = MediaResponse(id: request.id)
            response.preview = .init(rasters: [.init(width: 2, height: 2)])
            response.preview?.imageType = request.preview?.imageType
            let json = try JSONEncoder().encode(response)
            try response.validate(for: request)
            state.reply()
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: json, as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyDoesNotParseOrReplayAndExplicitSameSourceLoadWorks() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolModelState(), worker = worker(state); var parses = 0
        let model = AskToolImageModel(worker: worker, readInput: { value in parses += 1; return try AskToolImageModel.input(value) })
        await model.load(source)
        #expect(model.source == source && model.image == nil && model.unavailable && parses == 0 && state.counts == [0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(model.image == nil && model.unavailable && parses == 0 && state.counts == [0, 0])
        await model.load(source)
        #expect(model.image != nil && !model.unavailable && parses == 1 && state.counts == [1, 1])
        model.cancel(); await registry.shutdown()
    }

    @Test func originalModelStampPrecedesParsingAndRetainsRawReceipt() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolModelState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let message = AskMessage(id: "original-output", role: "tool", text: "completed", image: source, createdAt: Date())
        var revoke = true, parses = 0
        let model = AskToolImageModel(worker: worker, readInput: { value in
            parses += 1
            if revoke { module.module.supervisor.admission.setEnabled(false) }
            return try AskToolImageModel.input(value)
        })
        await model.load(try #require(message.retainedResultImages.first))
        #expect(model.image == nil && model.unavailable && parses == 1 && state.counts == [0, 0])
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(parses == 1 && state.counts == [0, 0], "Recovery must not replay parsing or producing work")
        revoke = false; await model.load(source)
        #expect(model.image != nil && parses == 2 && state.counts == [1, 1])
        #expect(message.image == source && message.text == "completed" && message.retainedResultImages == [source])
        model.cancel(); await registry.shutdown()
    }

    @Test func canceledNativeWorkRetainsBothPixelReservationsUntilReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolModelState(), gate = ToolModelGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let budget = AskToolPixelBudget(limit: 2 * 1600 * 1600 * 4)
        let a = AskToolImageModel(budget: budget, worker: worker), b = AskToolImageModel(budget: budget, worker: worker)
        let ta = Task { await a.load(source) }, tb = Task { await b.load(source) }
        await wait { gate.count == 2 }; ta.cancel(); tb.cancel(); a.cancel(); b.cancel()
        #expect(worker.activeCount == 2)
        let c = AskToolImageModel(budget: budget, worker: worker)
        await c.load(source)
        #expect(c.image == nil && c.unavailable && state.counts == [2, 0])
        gate.release(); await ta.value; await tb.value
        #expect(a.image == nil && b.image == nil && worker.activeCount == 0 && state.counts == [2, 2])
        await c.load(source)
        #expect(c.image != nil && !c.unavailable && state.counts == [3, 3])
        a.cancel(); b.cancel(); c.cancel(); await registry.shutdown()
    }

    @Test func validLateNativeReplyCannotPublishAfterOriginalAdmissionRevocation() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ToolModelState(), gate = ToolModelGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let model = AskToolImageModel(worker: worker)
        let old = Task { await model.load(source) }
        await wait { gate.count == 1 }
        module.module.supervisor.admission.setEnabled(false)
        gate.release(); await old.value
        #expect(state.counts == [1, 1] && worker.activeCount == 0 && model.image == nil && model.unavailable)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == [1, 1] && model.image == nil)
        await model.load(source)
        #expect(state.counts == [2, 2] && model.image != nil)
        model.cancel(); await registry.shutdown()
    }

    @Test func canceledOldEntryPreservesNewPixelsAndCustomActorIsIndependent() async throws {
        let state = ToolModelState(), worker = worker(state), decoder = ToolModelDecoder()
        var parses = 0
        let model = AskToolImageModel(worker: worker, readInput: { value in parses += 1; return try AskToolImageModel.input(value) },
                                     decode: { bytes, _ in await decoder.decode(bytes) })
        await model.load(newer)
        let snapshot = try #require(model.image)
        let canceled = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.load(source) }
        await canceled.value
        #expect(model.image === snapshot && model.source == newer && !model.unavailable && parses == 1 && state.counts == [0, 0])
        #expect(await decoder.calls == 1)
        model.cancel()
        let cancelInParser = AskToolImageModel(worker: worker, readInput: { value in
            withUnsafeCurrentTask { $0?.cancel() }; return try AskToolImageModel.input(value)
        }, decode: { _, _ in Issue.record("Canceled preparation reached decoder"); throw CancellationError() })
        let task = Task { await cancelInParser.load(source) }; await task.value
        #expect(cancelInParser.image == nil && !cancelInParser.unavailable)
    }

    @Test func oldUncooperativeCustomResultCannotReplaceNewSelection() async {
        let decoder = ToolModelDecoder()
        let model = AskToolImageModel(decode: { bytes, _ in await decoder.decode(bytes, hold: bytes == Data([1, 2, 3])) })
        let old = Task { await model.load(source) }
        let end = ContinuousClock.now + .seconds(5)
        while !(await decoder.waiting), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await decoder.waiting)
        await model.load(newer)
        let snapshot = model.image; #expect(snapshot != nil)
        await decoder.release(); await old.value
        #expect(model.image === snapshot && model.source == newer && !model.unavailable)
        #expect(await decoder.calls == 2)
        model.cancel()
    }

    @Test func pureInputLimitsAndCustomFailureGeometryRemainCompatible() async throws {
        for type in [MediaImageType.png, .jpeg, .gif] {
            let (bytes, parsed) = try AskToolImageModel.input("data:\(type.rawValue);base64,AQID")
            #expect(bytes == Data([1, 2, 3]) && parsed == type)
        }
        #expect(try AskToolImageModel.input("data:image/png;base64,").0.isEmpty, "Preserve existing parser contract; downstream native still rejects empty data")
        for value in ["", "https://private.invalid/image", "data:image/png,AQID", "data:image/svg+xml;base64,AQID", "data:image/png;base64,@@@",
                      String(repeating: "a", count: 16 * 1024 * 1024 + 1)] {
            #expect(throws: (any Error).self) { _ = try AskToolImageModel.input(value) }
        }
        for pixels in [[], [AskAttachmentFixture.image(width: 1601, height: 1)]] {
            let model = AskToolImageModel(decode: { _, _ in .init(images: pixels, numbers: [], pages: 0) })
            await model.load(source)
            #expect(model.image == nil && model.unavailable && model.source == source)
            model.cancel()
        }
        let failed = AskToolImageModel(decode: { _, _ in throw MediaFailure.unavailable })
        await failed.load(source); #expect(failed.unavailable && failed.image == nil)
        await failed.load("invalid"); #expect(failed.unavailable && failed.source == "invalid")
        failed.cancel()
    }

    @Test func completedPixelsReleaseOnCancelAndModelDeinit() async {
        let budget = AskToolPixelBudget(limit: 1600 * 1600 * 4), decoder = ToolModelDecoder()
        var first: AskToolImageModel? = AskToolImageModel(budget: budget, decode: { bytes, _ in await decoder.decode(bytes) })
        let second = AskToolImageModel(budget: budget, decode: { bytes, _ in await decoder.decode(bytes) })
        await first?.load(source); #expect(first?.image != nil)
        await second.load(source); #expect(second.image == nil && second.unavailable)
        #expect(await decoder.calls == 1)
        first?.cancel(); await second.load(source); #expect(second.image != nil)
        second.cancel(); await first?.load(source); #expect(first?.image != nil)
        first = nil; await second.load(source); #expect(second.image != nil)
        second.cancel()
        #expect(await decoder.calls == 4)
    }
}
