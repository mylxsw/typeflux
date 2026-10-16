import AppKit
import Darwin
import SwiftUI
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class FileIconCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0, runs = 0, valid = 0
    private var firstClockTask: Int?
    var values: [Int] { lock.withLock { [reads, runs, valid] } }
    var clockTask: Int? { lock.withLock { firstClockTask } }
    func read() { lock.withLock { reads += 1 } }
    func run() -> Int { lock.withLock { runs += 1; return runs } }
    func finish() { lock.withLock { valid += 1 } }
    func clock() -> TimeInterval {
        // Observe the existing budget clock without retaining a task or changing scheduling.
        let task = withUnsafeCurrentTask { $0?.hashValue }
        lock.withLock { if firstClockTask == nil { firstClockTask = task } }
        return ProcessInfo.processInfo.systemUptime
    }
}
private final class FileIconGate: @unchecked Sendable {
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
private actor IndependentFileIcon {
    private(set) var calls = 0
    func image() -> CGImage { calls += 1; return AskAttachmentFixture.image(width: 2, height: 2) }
}

@Suite("Small file icon accepted native batch", .exclusiveUIState)
@MainActor struct SmallFileIconBatchAuthorityTests {
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func worker(_ counts: FileIconCounts, managed: Bool = true, gate: FileIconGate? = nil,
                        firstOnly: Bool = false, observeClock: Bool = false) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: managed,
            uptime: { observeClock ? counts.clock() : ProcessInfo.processInfo.systemUptime }, run: { p, _ in
                let number = counts.run()
                if !firstOnly || number == 1 { gate?.wait() }
                let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
                #expect(request.operation == .previewImage && request.preview?.width == 56 && request.preview?.height == 56)
                let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw MediaFailure.unavailable }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? file.close() }
                try file.write(contentsOf: Data(repeating: 128, count: 16))
                var response = MediaResponse(id: request.id)
                response.preview = .init(rasters: [.init(width: 2, height: 2)])
                response.preview?.imageType = request.preview?.imageType
                try response.validate(for: request); counts.finish()
                return .init(termination: .exited(0), exitCode: 0,
                    stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
    }
    private func preparation(_ url: URL, _ worker: MediaWorker, _ counts: FileIconCounts,
                             gate: FileIconGate? = nil) -> AskSmallFileIconPreparation {
        .init(url: url, worker: worker, readInput: { input in
            counts.read(); gate?.wait(); return try AskSmallIconDecoder.read(input)
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func defaultOuterBindingRunsInAcceptedCallerBeforeQueuedDecoderTask() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private"), bytes = Data([1, 2, 3])
        try bytes.write(to: url)
        let counts = FileIconCounts(), worker = worker(counts, managed: false, observeClock: true)
        let scope = AskImagePresentationScope()
        let model = AskContextImageModel(maximumEdge: 56, smallFileIcon: preparation(url, worker, counts))
        let caller = withUnsafeCurrentTask { $0?.hashValue }
        #expect(caller != nil && counts.clockTask == nil)
        await model.load(url.absoluteString, access: access(scope))
        #expect(counts.clockTask == caller, "The existing availability clock must first run in the accepted caller, before Context's child Task")
        #expect(model.image != nil && counts.values == [1, 1, 1])
        #expect(try Data(contentsOf: url) == bytes)
        scope.invalidate(); await worker.shutdown()
    }

    @Test func preReadyAndCanceledDefaultModelCannotPrepareOrReplayFailedIdentity() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private"); try Data([1]).write(to: url)
        let counts = FileIconCounts(), worker = worker(counts), scope = AskImagePresentationScope()
        let prep = preparation(url, worker, counts), frozen = prep.bind(url.absoluteString)
        let model = AskContextImageModel(maximumEdge: 56, smallFileIcon: prep)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(url.absoluteString, access: access(scope))
        }
        await canceled.value
        #expect(!model.unavailable && counts.values == [0, 0, 0])
        await model.load(url.absoluteString, access: access(scope))
        #expect(model.unavailable && counts.values == [0, 0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        do { _ = try await frozen.decode(); Issue.record("Pre-ready batch upgraded") } catch {}
        await model.load(url.absoluteString, access: access(scope))
        #expect(model.unavailable && counts.values == [0, 0, 0])
        model.cancel(); await model.load(url.absoluteString, access: access(scope))
        #expect(model.displayed(url.absoluteString, access: access(scope)) != nil && counts.values == [1, 1, 1])
        let before = counts.values
        do { _ = try await prep.bind("foreign").decode(); Issue.record("Mismatched source") } catch {}
        #expect(counts.values == before)
        scope.invalidate(); await registry.shutdown()
    }

    @Test func heldDefaultPreparationAndFrozenBatchKeepOriginalManagedGeneration() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private"), bytes = Data([1, 2, 3]); try bytes.write(to: url)
        let counts = FileIconCounts(), gate = FileIconGate(), worker = worker(counts)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let prep = preparation(url, worker, counts, gate: gate), frozen = prep.bind(url.absoluteString)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, smallFileIcon: prep)
        let old = Task { await model.load(url.absoluteString, access: access(scope)) }
        await wait { gate.count == 1 }; #expect(worker.activeCount == 0)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        do { _ = try await frozen.decode(); Issue.record("Original batch upgraded") } catch {}
        #expect(counts.values == [1, 0, 0])
        gate.release(); await old.value
        #expect(model.unavailable && model.image == nil && counts.values == [1, 0, 0])
        await model.load(url.absoluteString, access: access(scope)); #expect(counts.values == [1, 0, 0])
        model.cancel(); await model.load(url.absoluteString, access: access(scope))
        #expect(model.image != nil && counts.values == [2, 1, 1])
        #expect(try Data(contentsOf: url) == bytes)
        scope.invalidate(); await registry.shutdown()
    }

    @Test(arguments: [false, true]) func canceledPreparationOrNativeWorkRetainsSlotsAndPixelsUntilReturn(_ native: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private"); try Data([1]).write(to: url)
        let counts = FileIconCounts(), gate = FileIconGate(), worker = worker(counts, gate: native ? gate : nil)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let budget = AskToolPixelBudget(limit: 2 * 56 * 56 * 4), scope = AskImagePresentationScope()
        let prep = preparation(url, worker, counts, gate: native ? nil : gate)
        let a = AskContextImageModel(budget: budget, maximumEdge: 56, smallFileIcon: prep)
        let b = AskContextImageModel(budget: budget, maximumEdge: 56, smallFileIcon: prep)
        let ta = Task { await a.load(url.absoluteString, access: access(scope)) }
        let tb = Task { await b.load(url.absoluteString, access: access(scope)) }
        await wait { gate.count == 2 }; ta.cancel(); tb.cancel(); a.cancel(); b.cancel()
        #expect(worker.activeCount == (native ? 2 : 0))
        let third = AskContextImageModel(budget: budget, maximumEdge: 56, smallFileIcon: prep)
        await third.load(url.absoluteString, access: access(scope)); #expect(third.unavailable)
        do { _ = try await AskSmallIconDecoder.decode(.file(url), worker: worker); Issue.record("Direct slots retired early") } catch {}
        #expect(counts.values == [2, native ? 2 : 0, 0])
        gate.release(); await ta.value; await tb.value
        #expect(a.image == nil && b.image == nil && worker.activeCount == 0)
        #expect(counts.values == [2, native ? 2 : 0, native ? 2 : 0])
        third.cancel(); await third.load(url.absoluteString, access: access(scope))
        #expect(third.image != nil)
        scope.invalidate(); await registry.shutdown()
    }

    @Test func validNativeResultThenTerminalRevocationCannotPublishButCompletedPixelsSurviveLaterHealth() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private"); try Data([1]).write(to: url)
        let counts = FileIconCounts(), worker = worker(counts)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(); var checks = 0
        let original = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            checks += 1
            if checks == 2 {
                #expect(counts.values == [1, 1, 1] && worker.activeCount == 0 && worker.permits(worker.authorization()))
                module.module.supervisor.admission.setEnabled(false)
            }
            return true
        })
        let model = AskContextImageModel(maximumEdge: 56, smallFileIcon: preparation(url, worker, counts))
        await model.load(url.absoluteString, access: original)
        #expect(model.image == nil && model.unavailable)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        await model.load(url.absoluteString, access: access(scope)); #expect(counts.values == [1, 1, 1])
        model.cancel(); await model.load(url.absoluteString, access: access(scope))
        let snapshot = model.image; #expect(snapshot != nil)
        module.module.supervisor.admission.setEnabled(false)
        #expect(model.displayed(url.absoluteString, access: access(scope)) === snapshot)
        scope.invalidate(); await registry.shutdown()
    }

    @Test func oldUncooperativeResultCannotReplaceFreshSelection() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private"); try Data([1]).write(to: url)
        let counts = FileIconCounts(), gate = FileIconGate(), worker = worker(counts, gate: gate, firstOnly: true)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, smallFileIcon: preparation(url, worker, counts))
        let oldAccess = access(scope), old = Task { await model.load(url.absoluteString, access: oldAccess) }
        await wait { gate.count == 1 }; scope.invalidate()
        await model.load(url.absoluteString, access: access(scope))
        let snapshot = model.image; #expect(snapshot != nil && worker.activeCount == 1)
        await model.load(url.absoluteString, access: oldAccess)
        gate.release(); await old.value
        #expect(model.image === snapshot && !model.unavailable && counts.values == [2, 2, 2] && worker.activeCount == 0)
        scope.invalidate(); await registry.shutdown()
    }

    @Test func customActorAndLegacyEnvironmentRemainIndependentOfUnreadyNativeWorker() async throws {
        let counts = FileIconCounts(), worker = worker(counts), custom = IndependentFileIcon()
        let url = URL(fileURLWithPath: "/private/no-read"), scope = AskImagePresentationScope()
        var environment = EnvironmentValues()
        environment.askSmallIconDecoder = { _ in await custom.image() }
        let decoder = environment.askSmallIconDecoder
        let prep = AskSmallFileIconPreparation(url: url, decode: decoder, worker: worker,
            readInput: { _ in Issue.record("Custom decoder forced onto native input"); throw MediaFailure.unavailable })
        let model = AskContextImageModel(maximumEdge: 56, smallFileIcon: prep)
        await model.load(url.absoluteString, access: access(scope)); await model.load(url.absoluteString, access: access(scope))
        #expect(model.image != nil && counts.values == [0, 0, 0])
        #expect(await custom.calls == 1)
        _ = try await decoder(url)
        #expect(await custom.calls == 2)
        // Values only; no task, native icon, symbol resolution, host or window is installed.
        _ = AskSmallFileIcon(url: url, symbol: "doc").body
        let _: AskSmallFileIconPreparation.Decoder = EnvironmentValues().askSmallIconDecoder
        scope.invalidate()
    }
}
