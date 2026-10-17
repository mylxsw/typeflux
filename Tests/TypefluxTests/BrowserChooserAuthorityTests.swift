import AppKit
import Darwin
import SwiftUI
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class BrowserChooserState: @unchecked Sendable {
    private let lock = NSLock()
    private var preview = 0, native = 0, valid = 0
    private var firstClock: Int?
    var counts: [Int] { lock.withLock { [preview, native, valid] } }
    var clockTask: Int? { lock.withLock { firstClock } }
    func clock() -> TimeInterval {
        let task = withUnsafeCurrentTask { $0?.hashValue }
        lock.withLock { if firstClock == nil { firstClock = task } }
        return ProcessInfo.processInfo.systemUptime
    }
    func run(_ operation: MediaRequest.Operation) {
        lock.withLock { if operation == .nativeIcon { native += 1 } else { preview += 1 } }
    }
    func finish() { lock.withLock { valid += 1 } }
}
private final class BrowserChooserGate: @unchecked Sendable {
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
private actor IndependentBrowserChooserDecoder {
    private(set) var calls = 0
    func decode() -> AskFilePreviewPDF.Result {
        calls += 1
        return .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
}

private actor BrowserChooserLoader {
    private(set) var calls = 0
    private var held: Bool
    private let output: Data?
    private let firstOnly: Bool
    private var waiting: [CheckedContinuation<Data?, Never>] = []
    init(held: Bool = false, output: Data? = Data([1, 2, 3]), firstOnly: Bool = false) { self.held = held; self.output = output; self.firstOnly = firstOnly }
    func load(_ url: URL) async -> Data? {
        calls += 1
        if held && (!firstOnly || calls == 1) { return await withCheckedContinuation { waiting.append($0) } }
        return output
    }
    func release() {
        held = false; let old = waiting; waiting.removeAll()
        old.forEach { $0.resume(returning: output) }
    }
}

@Suite("Browser chooser original accepted native branches", .exclusiveUIState)
@MainActor struct BrowserChooserAuthorityTests {
    private let site = URL(string: "https://private.test/favicon.ico")!
    private let app = MediaNativeIcon(kind: .application, value: "private.fixture.application")
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func worker(_ state: BrowserChooserState, managed: Bool = true,
                        gate: BrowserChooserGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: managed,
            uptime: { state.clock() }, run: { p, _ in
                let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
                try request.validate()
                #expect([MediaRequest.Operation.previewImage, .nativeIcon].contains(request.operation))
                #expect(request.preview?.width == 56 && request.preview?.height == 56)
                state.run(request.operation); gate?.wait()
                let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw MediaFailure.unavailable }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
                try handle.write(contentsOf: Data(repeating: 128, count: 16))
                var response = MediaResponse(id: request.id)
                response.preview = .init(rasters: [.init(width: 2, height: 2)])
                response.preview?.imageType = request.preview?.imageType
                try response.validate(for: request); state.finish()
                return .init(termination: .exited(0), exitCode: 0,
                    stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
    }
    private func prep(_ cache: AskBrowserFaviconCache, _ worker: MediaWorker) -> AskBrowserIconPreparation {
        .init(url: site, cache: cache, fallback: app, worker: worker)
    }
    private func wait(_ predicate: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }

    @Test(arguments: [false, true])
    func bothDefaultBranchesSnapshotInAcceptedCallerBeforeContextTask(favicon: Bool) async throws {
        let iconState = BrowserChooserState(), fallbackState = BrowserChooserState()
        let iconWorker = worker(iconState, managed: false), fallbackWorker = worker(fallbackState, managed: false)
        let loader = BrowserChooserLoader(output: favicon ? Data([1]) : nil)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: iconWorker)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, fallbackWorker))
        let caller = withUnsafeCurrentTask { $0?.hashValue }
        await model.load(site.absoluteString, access: access(scope))
        #expect(caller != nil && iconState.clockTask == caller && fallbackState.clockTask == caller)
        #expect(model.image != nil && iconState.counts == (favicon ? [1, 0, 1] : [0, 0, 0]))
        #expect(fallbackState.counts == (favicon ? [0, 0, 0] : [0, 1, 1]))
        #expect(await loader.calls == 1)
        scope.invalidate(); cache.cancel(); await iconWorker.shutdown(); await fallbackWorker.shutdown()
    }

    @Test func preReadyAndPrecanceledRetainFailureIdentityAndCooldownWithoutReplay() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = BrowserChooserState(), worker = worker(state), loader = BrowserChooserLoader()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, clock: { now }, worker: worker)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, worker))
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(site.absoluteString, access: access(scope))
        }
        await canceled.value
        #expect(!model.unavailable && state.clockTask == nil)
        await model.load(site.absoluteString, access: access(scope))
        #expect(model.unavailable && state.counts == [0, 0, 0]); #expect(await loader.calls == 0)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        await model.load(site.absoluteString, access: access(scope))
        #expect(state.counts == [0, 0, 0]); #expect(await loader.calls == 0)
        model.cancel(); await model.load(site.absoluteString, access: access(scope))
        #expect(model.image != nil && state.counts == [0, 1, 1]); #expect(await loader.calls == 0)
        now += 60; model.cancel(); await model.load(site.absoluteString, access: access(scope))
        #expect(model.image != nil && state.counts == [1, 1, 2]); #expect(await loader.calls == 1)
        do { _ = try prep(cache, worker).bind("foreign", access: access(scope)); Issue.record("Foreign source bound") } catch {}
        scope.invalidate(); cache.cancel(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func heldFaviconCannotUpgradeEitherNativeBranchAfterManagedRecovery(bytes: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = BrowserChooserState(), worker = worker(state), loader = BrowserChooserLoader(held: true, output: bytes ? Data([1]) : nil)
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, clock: { now }, worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(), model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, worker))
        let old = Task { await model.load(site.absoluteString, access: access(scope)) }
        await wait { await loader.calls == 1 }
        #expect(worker.activeCount == 0)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        await loader.release(); await old.value
        #expect(model.image == nil && model.unavailable && state.counts == [0, 0, 0])
        await model.load(site.absoluteString, access: access(scope)); #expect(await loader.calls == 1)
        now += 60; model.cancel(); await model.load(site.absoluteString, access: access(scope))
        #expect(model.image != nil && state.counts == (bytes ? [1, 0, 1] : [0, 1, 1]))
        #expect(await loader.calls == 2)
        scope.invalidate(); cache.cancel(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func terminalSourceCheckRevalidatesOnlyChosenNativeBranch(favicon: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = BrowserChooserState(), worker = worker(state), loader = BrowserChooserLoader(output: favicon ? Data([1]) : nil)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(), original = worker.authorization(); var afterValid = 0, revoked = false
        let permission = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            if state.counts[2] == 1 {
                afterValid += 1
                // Favicon's two terminal cache authorizers precede Context's terminal authorizer.
                if !revoked && afterValid == (favicon ? 3 : 1) {
                    #expect(worker.activeCount == 0 && worker.permits(original))
                    revoked = true; module.module.supervisor.admission.setEnabled(false)
                }
            }
            return true
        })
        let model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, worker))
        await model.load(site.absoluteString, access: permission)
        #expect(revoked && model.image == nil && model.unavailable && state.counts[2] == 1)
        #expect((cache.cached(site, access: access(scope)) != nil) == favicon)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        await model.load(site.absoluteString, access: access(scope)); #expect(state.counts[2] == 1)
        model.cancel(); cache.cancel(); await model.load(site.absoluteString, access: access(scope))
        let pixels = model.image; #expect(pixels != nil && state.counts[2] == 2)
        module.module.supervisor.admission.setEnabled(false)
        #expect(model.displayed(site.absoluteString, access: access(scope)) === pixels)
        scope.invalidate(); cache.cancel(); await registry.shutdown()
    }

    @Test func sharedConsumersRetainOnePendingWhenOneOwnerCancels() async throws {
        let state = BrowserChooserState(), worker = worker(state, managed: false), loader = BrowserChooserLoader(held: true)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker)
        let scope = AskImagePresentationScope(), preparation = prep(cache, worker)
        let a = AskContextImageModel(maximumEdge: 56, browserIcon: preparation)
        let b = AskContextImageModel(maximumEdge: 56, browserIcon: preparation)
        let ta = Task { await a.load(site.absoluteString, access: access(scope)) }
        await wait { await loader.calls == 1 }
        var joined = false
        let tb = Task { joined = true; await b.load(site.absoluteString, access: access(scope)) }
        await wait { joined }; ta.cancel(); a.cancel()
        await loader.release(); await ta.value; await tb.value
        #expect(a.image == nil && b.image != nil && state.counts == [1, 0, 1]); #expect(await loader.calls == 1)
        scope.invalidate(); cache.cancel(); await worker.shutdown()
    }

    @Test func retiredOuterConsumerCannotJoinANewerNativePendingRequest() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = BrowserChooserState(), gate = BrowserChooserGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let cache = AskBrowserFaviconCache(loader: { _ in Data([1]) }, worker: worker), scope = AskImagePresentationScope()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let frozen = try prep(cache, worker).bind(site.absoluteString, access: access(scope))
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        let model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, worker))
        let fresh = Task { await model.load(site.absoluteString, access: access(scope)) }
        await wait { gate.count == 1 }
        var finished = false
        let old = Task {
            do { _ = try await frozen.decode(); Issue.record("Retired consumer adopted new pending") } catch {}
            finished = true
        }
        await wait { finished }
        #expect(state.counts == [1, 0, 0] && worker.activeCount == 1)
        gate.release(); await old.value; await fresh.value
        #expect(model.image != nil && state.counts == [1, 0, 1])
        scope.invalidate(); cache.cancel(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func canceledSourceOrNativeConsumersRetainPhysicalCapacityUntilReturn(native: Bool) async throws {
        let state = BrowserChooserState(), gate = BrowserChooserGate(), worker = worker(state, managed: false, gate: native ? gate : nil)
        defer { gate.release() }
        let loader = BrowserChooserLoader(held: !native)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker)
        let secondSite = URL(string: "https://second.test/favicon.ico")!
        let scope = AskImagePresentationScope(), budget = AskToolPixelBudget(limit: 2 * 56 * 56 * 4)
        let a = AskContextImageModel(budget: budget, maximumEdge: 56, browserIcon: prep(cache, worker))
        let b = AskContextImageModel(budget: budget, maximumEdge: 56,
            browserIcon: .init(url: secondSite, cache: cache, fallback: app, worker: worker))
        let ta = Task { await a.load(site.absoluteString, access: access(scope)) }
        let tb = Task { await b.load(secondSite.absoluteString, access: access(scope)) }
        await wait { if native { return gate.count == 2 }; return await loader.calls == 2 }
        ta.cancel(); tb.cancel(); a.cancel(); b.cancel(); cache.cancel()
        #expect(worker.activeCount == (native ? 2 : 0))
        let third = AskContextImageModel(budget: budget, maximumEdge: 56, browserIcon: prep(cache, worker))
        await third.load(site.absoluteString, access: access(scope)); #expect(third.unavailable)
        #expect(await loader.calls == 2)
        await loader.release(); gate.release(); await ta.value; await tb.value
        #expect(worker.activeCount == 0 && a.image == nil && b.image == nil)
        third.cancel(); await third.load(site.absoluteString, access: access(scope))
        #expect(third.image != nil && state.counts == (native ? [3, 0, 3] : [1, 0, 1]))
        scope.invalidate(); cache.cancel(); await worker.shutdown()
    }

    @Test func completedFaviconAndCustomActorsIgnoreUnusedUnavailableFallback() async throws {
        let state = BrowserChooserState(), worker = worker(state), custom = IndependentBrowserChooserDecoder()
        let pixels = AskAttachmentFixture.image(width: 2, height: 2)
        let cache = AskBrowserFaviconCache(loader: { _ in Data([1]) }, worker: worker, decode: { _ in pixels })
        let scope = AskImagePresentationScope()
        let model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, worker))
        await model.load(site.absoluteString, access: access(scope)); #expect(model.image != nil && state.counts == [0, 0, 0])
        model.cancel(); await model.load(site.absoluteString, access: access(scope)); #expect(model.image != nil)
        var environment = EnvironmentValues(); environment.askNativeIconDecoder = { _ in await custom.decode() }
        let unavailableCache = AskBrowserFaviconCache(loader: { _ in Issue.record("Pre-ready loader"); return nil }, worker: worker)
        let preparation = AskBrowserIconPreparation(url: site, cache: unavailableCache, fallback: app,
            decode: environment.askNativeIconDecoder, worker: worker)
        let fallback = AskContextImageModel(maximumEdge: 56, browserIcon: preparation)
        await fallback.load(site.absoluteString, access: access(scope))
        #expect(fallback.image != nil && state.counts == [0, 0, 0]); #expect(await custom.calls == 1)
        let explicit = AskContextImageModel(maximumEdge: 56, browserIcon: prep(unavailableCache, worker)) { _ in await custom.decode() }
        await explicit.load(site.absoluteString, access: access(scope)); #expect(explicit.image != nil)
        let missing = AskContextImageModel(maximumEdge: 56, browserIcon: .init(url: site, cache: unavailableCache, worker: worker))
        await missing.load(site.absoluteString, access: access(scope)); #expect(missing.unavailable)
        let nativeState = BrowserChooserState(), nativeWorker = self.worker(nativeState, managed: false)
        let nativeCache = AskBrowserFaviconCache(loader: { _ in Data([1]) }, worker: nativeWorker)
        let nativeModel = AskContextImageModel(maximumEdge: 56, browserIcon: prep(nativeCache, worker))
        await nativeModel.load(site.absoluteString, access: access(scope))
        #expect(nativeModel.image != nil && nativeState.counts == [1, 0, 1] && state.counts == [0, 0, 0])
        nativeWorker.preventNewWork()
        let completed = AskContextImageModel(maximumEdge: 56, browserIcon: prep(nativeCache, worker))
        await completed.load(site.absoluteString, access: access(scope))
        #expect(completed.image != nil && nativeState.counts == [1, 0, 1])
        nativeCache.cancel(); await nativeWorker.shutdown()
        // Body values only: no host, rendering, Environment installation or task launch.
        _ = AskBrowserFaviconView(url: site, fallback: URL(fileURLWithPath: "/private/no-read"), symbol: "doc", filled: false, cache: cache).body
        _ = AskBrowserFaviconView(url: site, fallback: nil, application: app.value, symbol: "doc", filled: false, cache: cache).body
        scope.invalidate(); cache.cancel(); unavailableCache.cancel(); await worker.shutdown()
    }

    @Test(arguments: [false, true])
    func sourceBindingCallbackCannotContinueCanceledContextAdmission(cancelTask: Bool) async throws {
        let state = BrowserChooserState(), worker = worker(state, managed: false), loader = BrowserChooserLoader()
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker), scope = AskImagePresentationScope()
        let model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, worker)); var checks = 0
        let permission = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            checks += 1
            if checks == 2 {
                if cancelTask { withUnsafeCurrentTask { $0?.cancel() } } else { model.cancel() }
            }
            return true
        })
        let task = Task { await model.load(site.absoluteString, access: permission) }
        await task.value
        #expect(model.image == nil && !model.unavailable && state.counts == [0, 0, 0]); #expect(await loader.calls == 0)
        cache.cancel(); await model.load(site.absoluteString, access: access(scope))
        #expect(model.image != nil && state.counts == [1, 0, 1])
        scope.invalidate(); cache.cancel(); await worker.shutdown()
    }

    @Test func oldHeldSourceCannotFallbackAfterCacheCancelOrReplaceFreshScope() async throws {
        let state = BrowserChooserState(), worker = worker(state, managed: false), loader = BrowserChooserLoader(held: true, firstOnly: true)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker), scope = AskImagePresentationScope()
        let model = AskContextImageModel(maximumEdge: 56, browserIcon: prep(cache, worker))
        let old = Task { await model.load(site.absoluteString, access: access(scope)) }
        await wait { await loader.calls == 1 }; scope.invalidate(); cache.cancel()
        await model.load(site.absoluteString, access: access(scope))
        let pixels = model.image; #expect(pixels != nil)
        // The old same-URL pending is still physically held, so the fresh explicit owner uses its fallback.
        let completed = state.counts; #expect(completed == [0, 1, 1])
        await loader.release(); await old.value
        #expect(model.image === pixels && state.counts == completed)
        scope.invalidate(); cache.cancel(); await worker.shutdown()
    }
}
