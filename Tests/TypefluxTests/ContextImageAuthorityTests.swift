import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class ContextAuthorityCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0, 0]
    var snapshot: [Int] { lock.withLock { values } }
    func parse() { lock.withLock { values[0] += 1 } }
    func run() { lock.withLock { values[1] += 1 } }
}
private final class ContextAuthorityGate: @unchecked Sendable {
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
private actor ContextIndependentDecoder {
    private(set) var calls = 0
    func decode(_ value: String) -> AskFilePreviewPDF.Result {
        calls += 1
        return .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
}

@Suite("Context image original native authority", .exclusiveUIState)
@MainActor struct ContextImageAuthorityTests {
    private let source = "data:image/png;base64,AQID"
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func reader(_ counts: ContextAuthorityCounts, gate: ContextAuthorityGate? = nil) -> AskContextImageDecoder.InputReader {
        { value in counts.parse(); gate?.wait(); return try AskContextImageDecoder.input(value) }
    }
    private func worker(_ counts: ContextAuthorityCounts, gate: ContextAuthorityGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            counts.run(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw MediaFailure.unavailable }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            try file.write(contentsOf: Data(repeating: 128, count: 16))
            var response = MediaResponse(id: request.id)
            response.preview = .init(rasters: [.init(width: 2, height: 2)])
            response.preview?.imageType = request.preview?.imageType
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyAndCanceledWorkCannotParseOrReplayAfterReadiness() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counts = ContextAuthorityCounts(), worker = worker(counts), read = reader(counts)
        let preReady = worker.authorization()
        let scope = AskImagePresentationScope(), model = AskContextImageModel(worker: worker, readInput: read)
        await model.load(source, access: access(scope))
        #expect(model.image == nil && model.unavailable && counts.snapshot == [0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        await model.load(source, access: access(scope))
        #expect(model.image == nil && model.unavailable && counts.snapshot == [0, 0], "Same failed identity must not retry")
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        for stamp in [preReady, foreign] {
            do { _ = try await AskContextImageDecoder.decode(source, worker: worker, authorization: stamp, readInput: read); Issue.record("Old stamp admitted") } catch {}
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AskContextImageDecoder.decode(source, worker: worker, readInput: read)
        }
        do { _ = try await canceled.value; Issue.record("Canceled parse") } catch is CancellationError {}
        #expect(counts.snapshot == [0, 0])
        model.cancel(); await model.load(source, access: access(scope))
        #expect(model.displayed(source, access: access(scope)) != nil && counts.snapshot == [1, 1])
        scope.invalidate(); await registry.shutdown()
    }

    @Test func heldDefaultModelInputCannotAdoptRecovery() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counts = ContextAuthorityCounts(), worker = worker(counts), gate = ContextAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(worker: worker, readInput: reader(counts, gate: gate))
        let old = Task { await model.load(source, access: access(scope)) }
        await wait { gate.count == 1 }; #expect(worker.activeCount == 0)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release(); await old.value
        #expect(model.image == nil && model.unavailable && counts.snapshot == [1, 0])
        await model.load(source, access: access(scope))
        #expect(counts.snapshot == [1, 0])
        model.cancel(); await model.load(source, access: access(scope))
        #expect(model.image != nil && counts.snapshot == [2, 1])
        #expect(source == "data:image/png;base64,AQID")
        scope.invalidate(); await registry.shutdown()
    }

    @Test func canceledPreparationsRetainBothSlotsAndModelPixelsUntilReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counts = ContextAuthorityCounts(), worker = worker(counts), gate = ContextAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(), budget = AskToolPixelBudget(limit: 2 * 1600 * 1600 * 4)
        let a = AskContextImageModel(budget: budget, worker: worker, readInput: reader(counts, gate: gate))
        let b = AskContextImageModel(budget: budget, worker: worker, readInput: reader(counts, gate: gate))
        let ta = Task { await a.load(source, access: access(scope)) }, tb = Task { await b.load(source, access: access(scope)) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        let c = AskContextImageModel(budget: budget, worker: worker, readInput: reader(counts))
        await c.load(source, access: access(scope))
        #expect(c.image == nil && c.unavailable)
        do { _ = try await AskContextImageDecoder.decode(source, worker: worker, readInput: reader(counts)); Issue.record("Occupied parse slots released") } catch {}
        #expect(counts.snapshot == [2, 0])
        gate.release(); await ta.value; await tb.value
        #expect(a.image == nil && b.image == nil && counts.snapshot == [2, 0])
        c.cancel(); await c.load(source, access: access(scope))
        #expect(c.image != nil && counts.snapshot == [3, 1])
        scope.invalidate(); await registry.shutdown()
    }

    @Test func canceledEnteredNativeWorkRetainsCapacityAndRejectsLatePixels() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counts = ContextAuthorityCounts(), gate = ContextAuthorityGate(), worker = worker(counts, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let a = Task { try await AskContextImageDecoder.decode(source, worker: worker, readInput: reader(counts)) }
        let b = Task { try await AskContextImageDecoder.decode(source, worker: worker, readInput: reader(counts)) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        #expect(worker.activeCount == 2)
        do { _ = try await AskContextImageDecoder.decode(source, worker: worker, readInput: reader(counts)); Issue.record("Occupied native work released") } catch {}
        #expect(counts.snapshot == [2, 2])
        gate.release()
        for task in [a, b] { do { _ = try await task.value; Issue.record("Late canceled pixels") } catch {} }
        #expect(worker.activeCount == 0)
        let fresh = try await AskContextImageDecoder.decode(source, worker: worker)
        #expect(fresh.images.first?.width == 2 && counts.snapshot == [2, 3])
        await registry.shutdown()
    }

    @Test func modelFinalNativeCheckRejectsRevocationAfterDecoderReturns() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counts = ContextAuthorityCounts(), worker = worker(counts)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(); var checks = 0
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            checks += 1
            if checks == 2 {
                #expect(worker.permits(worker.authorization()), "Valid native completion must precede UI revocation")
                worker.preventNewWork()
            }
            return true
        })
        let model = AskContextImageModel(worker: worker, readInput: reader(counts))
        await model.load(source, access: access)
        #expect(model.image == nil && model.unavailable && counts.snapshot == [1, 1] && worker.activeCount == 0)
        scope.invalidate(); await registry.shutdown()
    }

    @Test func customActorDecoderRemainsIndependentAndMalformedDefaultInputDoesNotPoisonHealth() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counts = ContextAuthorityCounts(), worker = worker(counts), custom = ContextIndependentDecoder()
        let scope = AskImagePresentationScope()
        let model = AskContextImageModel(worker: worker, readInput: { _ in Issue.record("Custom input forced onto native parser"); throw MediaFailure.unavailable },
                                        decode: { await custom.decode($0) })
        await model.load("independent", access: access(scope)); await model.load("independent", access: access(scope))
        #expect(model.image != nil && counts.snapshot == [0, 0])
        #expect(await custom.calls == 1)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        do { _ = try await AskContextImageDecoder.decode("malformed", worker: worker); Issue.record("Invalid input") } catch {}
        #expect(worker.permits(worker.authorization()) && counts.snapshot == [0, 0])
        _ = try await AskContextImageDecoder.decode(source, worker: worker)
        #expect(counts.snapshot == [0, 1])
        scope.invalidate(); await registry.shutdown()
    }
}
