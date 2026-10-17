import AppKit
import Darwin
import SwiftUI
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class NativeModelState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, valid = 0
    private var firstClock: Int?
    var counts: [Int] { lock.withLock { [runs, valid] } }
    var clockTask: Int? { lock.withLock { firstClock } }
    func clock() -> TimeInterval {
        let task = withUnsafeCurrentTask { $0?.hashValue }
        lock.withLock { if firstClock == nil { firstClock = task } }
        return ProcessInfo.processInfo.systemUptime
    }
    func run() -> Int { lock.withLock { runs += 1; return runs } }
    func finish() { lock.withLock { valid += 1 } }
}
private final class NativeModelGate: @unchecked Sendable {
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
private actor IndependentNativeModelDecoder {
    private(set) var calls = 0
    func decode() -> AskFilePreviewPDF.Result {
        calls += 1
        return .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
}

@Suite("Native icon accepted Context consumer", .exclusiveUIState)
@MainActor struct NativeIconModelAuthorityTests {
    private let app = MediaNativeIcon(kind: .application, value: "private.fixture.application")
    private func worker(_ state: NativeModelState, managed: Bool = true,
                        gate: NativeModelGate? = nil, firstOnly: Bool = false) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: managed,
            uptime: { state.clock() }, run: { p, _ in
                let number = state.run()
                if !firstOnly || number == 1 { gate?.wait() }
                let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
                try request.validate()
                #expect(request.operation == .nativeIcon && request.preview?.width == 56 && request.preview?.height == 56)
                #expect(request.preview?.imageType == nil && request.icon != nil)
                let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw MediaFailure.unavailable }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(repeating: 128, count: 16))
                var response = MediaResponse(id: request.id)
                response.preview = .init(rasters: [.init(width: 2, height: 2)])
                try response.validate(for: request); state.finish()
                return .init(termination: .exited(0), exitCode: 0,
                    stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
    }
    private func wait(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }


    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func source(_ icon: MediaNativeIcon) -> String { icon.kind.rawValue + ":" + icon.value }
    private func prep(_ worker: MediaWorker, cache: AskLauncherIconCache? = nil,
                      icon: MediaNativeIcon? = nil, revision: Date? = nil) -> AskNativeIconPreparation {
        .init(icon: icon ?? app, revision: revision, cache: cache, worker: worker)
    }

    @Test(arguments: [false, true])
    func defaultDirectAndCacheBindInAcceptedCallerBeforeContextTask(cached: Bool) async throws {
        let state = NativeModelState(), worker = worker(state, managed: false)
        let foreign = self.worker(NativeModelState())
        let cache = cached ? AskLauncherIconCache(immediateLookup: { _, _ in
            Issue.record("Binding performed immediate system lookup"); return nil
        }, worker: worker) : nil
        let preparation = prep(cached ? foreign : worker, cache: cache)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, nativeIcon: preparation)
        let caller = withUnsafeCurrentTask { $0?.hashValue }
        #expect(caller != nil && state.clockTask == nil)
        await model.load(source(app), access: access(scope))
        #expect(state.clockTask == caller && state.counts == [1, 1] && model.image != nil)
        #expect(cache == nil || cache?.cached(app) != nil)
        scope.invalidate(); cache?.clear(); await worker.shutdown(); await foreign.shutdown()
    }

    @Test(arguments: [false, true])
    func preReadyAndPrecanceledCannotDispatchOrReplayFailedIdentity(cached: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeModelState(), worker = worker(state)
        let cache = cached ? AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker) : nil
        let preparation = prep(worker, cache: cache), frozen = try preparation.bind(source(app))
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, nativeIcon: preparation)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(source(app), access: access(scope))
        }
        await canceled.value
        #expect(!model.unavailable && state.counts == [0, 0])
        await model.load(source(app), access: access(scope))
        #expect(model.unavailable && state.counts == [0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        do { _ = try await frozen.decode(); Issue.record("Old pre-ready consumer upgraded") } catch {}
        await model.load(source(app), access: access(scope))
        #expect(model.unavailable && state.counts == [0, 0])
        model.cancel(); await model.load(source(app), access: access(scope))
        #expect(model.image != nil && state.counts == [1, 1])
        do { _ = try preparation.bind("foreign"); Issue.record("Foreign source bound") } catch {}
        let missing = AskNativeIconPreparation(icon: nil, worker: worker)
        do { _ = try missing.bind(source(app)); Issue.record("Missing target bound") } catch {}
        scope.invalidate(); cache?.clear(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func originalManagedBatchSurvivesRecoveryWithoutUpgrading(cached: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeModelState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let cache = cached ? AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker) : nil
        let preparation = prep(worker, cache: cache), frozen = try preparation.bind(source(app))
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(!frozen.isCurrent())
        do { _ = try await frozen.decode(); Issue.record("Retired outer native request upgraded") } catch {}
        #expect(state.counts == [0, 0] && cache?.cached(app) == nil)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, nativeIcon: preparation)
        await model.load(source(app), access: access(scope))
        #expect(model.image != nil && state.counts == [1, 1])
        scope.invalidate(); cache?.clear(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func validCollectedNativeResultThenTerminalRevocationCannotPublish(cached: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeModelState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let cache = cached ? AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker) : nil
        let original = worker.authorization(), scope = AskImagePresentationScope(); var checks = 0
        let permission = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            checks += 1
            if checks == 2 {
                #expect(state.counts == [1, 1] && worker.activeCount == 0 && worker.permits(original))
                module.module.supervisor.admission.setEnabled(false)
            }
            return true
        })
        let model = AskContextImageModel(maximumEdge: 56, nativeIcon: prep(worker, cache: cache))
        await model.load(source(app), access: permission)
        #expect(model.image == nil && model.unavailable && state.counts == [1, 1])
        // A completed cache value remains durable even if the consumer was revoked later.
        if cached { #expect(cache?.cached(app) != nil); cache?.clear() }
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        await model.load(source(app), access: access(scope)); #expect(state.counts == [1, 1])
        model.cancel(); await model.load(source(app), access: access(scope))
        let pixels = model.image; #expect(pixels != nil)
        module.module.supervisor.admission.setEnabled(false)
        #expect(model.displayed(source(app), access: access(scope)) === pixels)
        scope.invalidate(); cache?.clear(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func canceledNativeConsumersKeepPhysicalCapacityAndPixelsUntilReturn(cached: Bool) async throws {
        let state = NativeModelState(), gate = NativeModelGate(), worker = worker(state, managed: false, gate: gate)
        defer { gate.release() }
        let cache = cached ? AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker) : nil
        let scope = AskImagePresentationScope(), budget = AskToolPixelBudget(limit: 2 * 56 * 56 * 4)
        let other = MediaNativeIcon(kind: .application, value: "private.other")
        let a = AskContextImageModel(budget: budget, maximumEdge: 56, nativeIcon: prep(worker, cache: cache))
        let b = AskContextImageModel(budget: budget, maximumEdge: 56, nativeIcon: prep(worker, cache: cache, icon: other))
        let ta = Task { await a.load(source(app), access: access(scope)) }
        let tb = Task { await b.load(source(other), access: access(scope)) }
        await wait { gate.count == 2 }; ta.cancel(); tb.cancel(); a.cancel(); b.cancel()
        #expect(worker.activeCount == 2 && state.counts == [2, 0])
        let third = AskContextImageModel(budget: budget, maximumEdge: 56, nativeIcon: prep(worker, cache: cache))
        await third.load(source(app), access: access(scope)); #expect(third.unavailable)
        gate.release(); await ta.value; await tb.value
        #expect(worker.activeCount == 0 && state.counts == [2, 2] && a.image == nil && b.image == nil)
        cache?.clear(); third.cancel(); await third.load(source(app), access: access(scope))
        #expect(third.image != nil && state.counts == [3, 3])
        scope.invalidate(); cache?.clear(); await worker.shutdown()
    }

    @Test func completedCacheIgnoresHealthButRetainsOriginalFileAndGlobalGeneration() async throws {
        let state = NativeModelState(), worker = worker(state), custom = IndependentNativeModelDecoder()
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker,
                                         decode: { _ in await custom.decode() })
        let file = MediaNativeIcon(kind: .file, value: "/private/no-read"), revision = Date(timeIntervalSince1970: 1_000)
        _ = try await cache.load(file, revision: revision); _ = try await cache.load(app)
        let fileBatch = try prep(worker, cache: cache, icon: file, revision: revision).bind(source(file))
        let appBatch = try prep(worker, cache: cache).bind(source(app))
        cache.clearFiles()
        #expect(!fileBatch.isCurrent() && appBatch.isCurrent())
        do { _ = try await fileBatch.decode(); Issue.record("Retired file cache projected") } catch {}
        _ = try await appBatch.decode(); cache.clear(); #expect(!appBatch.isCurrent())
        #expect(state.counts == [0, 0]); #expect(await custom.calls == 2)

        // Exercise completed DEFAULT-native cache through a fresh Context consumer after revocation.
        let readyState = NativeModelState(), readyWorker = self.worker(readyState, managed: false)
        let nativeCache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: readyWorker)
        _ = try await nativeCache.load(app); readyWorker.preventNewWork()
        let scope = AskImagePresentationScope()
        let model = AskContextImageModel(maximumEdge: 56, nativeIcon: prep(worker, cache: nativeCache))
        await model.load(source(app), access: access(scope))
        #expect(model.image != nil && readyState.counts == [1, 1] && state.counts == [0, 0])
        scope.invalidate(); nativeCache.clear(); await readyWorker.shutdown(); await worker.shutdown()
    }

    @Test func terminalSourceRevocationAndOldCompletionCannotReplaceFreshScope() async throws {
        let state = NativeModelState(), gate = NativeModelGate(), worker = worker(state, managed: false, gate: gate, firstOnly: true)
        defer { gate.release() }
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        let file = MediaNativeIcon(kind: .file, value: "/private/no-read"), revision = Date(timeIntervalSince1970: 1_000)
        let scope = AskImagePresentationScope()
        let model = AskContextImageModel(maximumEdge: 56, nativeIcon: prep(worker, cache: cache, icon: file, revision: revision))
        let old = Task { await model.load(source(file), access: access(scope)) }
        await wait { gate.count == 1 }; scope.invalidate(); cache.clearFiles()
        await model.load(source(file), access: access(scope))
        let pixels = model.image; #expect(pixels != nil && worker.activeCount == 1)
        gate.release(); await old.value
        #expect(model.image === pixels && state.counts == [2, 2] && worker.activeCount == 0)
        model.cancel(); var checks = 0
        let permission = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            checks += 1
            if checks == 2 { cache.clearFiles() }
            return true
        })
        // The completed value is accepted, then its ORIGINAL file generation is retired at the final source callback.
        await model.load(source(file), access: permission)
        #expect(model.image == nil && model.unavailable && state.counts == [2, 2])
        model.cancel(); await model.load(source(file), access: access(scope))
        #expect(model.image != nil && state.counts == [3, 3])
        scope.invalidate(); cache.clear(); await worker.shutdown()
    }

    @Test func customActorEnvironmentExplicitAndCacheContractsRemainIndependent() async throws {
        let state = NativeModelState(), worker = worker(state), custom = IndependentNativeModelDecoder()
        var environment = EnvironmentValues()
        environment.askNativeIconDecoder = { _ in await custom.decode() }
        let decoder = environment.askNativeIconDecoder
        let scope = AskImagePresentationScope()
        let direct = AskNativeIconPreparation(icon: app, decode: decoder, worker: worker)
        let model = AskContextImageModel(maximumEdge: 56, nativeIcon: direct)
        await model.load(source(app), access: access(scope)); await model.load(source(app), access: access(scope))
        #expect(model.image != nil && state.counts == [0, 0]); #expect(await custom.calls == 1)
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker,
                                         decode: { _ in await custom.decode() })
        let cacheWins = AskNativeIconPreparation(icon: app, cache: cache,
            decode: { _ in Issue.record("Environment override displaced cache"); throw MediaFailure.unavailable }, worker: worker)
        let cachedModel = AskContextImageModel(maximumEdge: 56, nativeIcon: cacheWins)
        await cachedModel.load(source(app), access: access(scope)); #expect(cachedModel.image != nil)
        let explicitWins = AskNativeIconPreparation(icon: app, cache: cache, decode: decoder, useCache: false, worker: worker)
        let explicitModel = AskContextImageModel(maximumEdge: 56, nativeIcon: explicitWins)
        await explicitModel.load(source(app), access: access(scope))
        #expect(explicitModel.image != nil && state.counts == [0, 0]); #expect(await custom.calls == 3)
        let contextOverride = AskContextImageModel(maximumEdge: 56, nativeIcon: prep(worker)) { _ in await custom.decode() }
        await contextOverride.load(source(app), access: access(scope)); #expect(contextOverride.image != nil)
        // Values only, default access denies and there is no cache/system lookup, host, task or window.
        _ = AskNativeIconImage(icon: app) { _ in EmptyView() }.body
        let _: AskNativeIconDecoding = EnvironmentValues().askNativeIconDecoder
        scope.invalidate(); cache.clear(); await worker.shutdown()
    }
}
