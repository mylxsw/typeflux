import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private actor FaviconAuthorityLoader {
    private(set) var calls: [URL] = []
    private var held: Set<URL>
    private var waiters: [URL: CheckedContinuation<Data?, Never>] = [:]
    init(held: Set<URL> = []) { self.held = held }
    func load(_ url: URL) async -> Data? {
        calls.append(url)
        if held.contains(url) { return await withCheckedContinuation { waiters[url] = $0 } }
        return Data([1, 2, 3])
    }
    func release() {
        held.removeAll(); let old = waiters; waiters.removeAll()
        old.values.forEach { $0.resume(returning: Data([1, 2, 3])) }
    }
}
private final class FaviconAuthorityNative: @unchecked Sendable {
    private let condition = NSCondition()
    private var runs = 0, valid = 0, held: Bool
    init(held: Bool = false) { self.held = held }
    var counts: (Int, Int) { condition.withLock { (runs, valid) } }
    func enter() {
        condition.lock(); defer { condition.unlock() }
        runs += 1
        while held { condition.wait() }
    }
    func finish() { condition.withLock { valid += 1 } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private actor FaviconIndependentDecoder {
    private(set) var count = 0
    func decode() -> CGImage { count += 1; return AskAttachmentFixture.image(width: 2, height: 2) }
}

@Suite("Favicon original pending native authority", .exclusiveUIState)
@MainActor struct FaviconBatchAuthorityTests {
    private func url(_ name: String) -> URL { URL(string: "https://\(name).test/favicon.ico")! }
    private func worker(_ state: FaviconAuthorityNative) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.enter()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            #expect(request.operation == .previewImage && request.preview?.width == 56)
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
    private func wait(_ predicate: () async -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }

    @Test func preReadyFailureKeepsCooldownAndNeedsExplicitRequestAfterExpiry() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = FaviconAuthorityNative(), worker = worker(state), loader = FaviconAuthorityLoader(), site = url("pre-ready")
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, clock: { now }, worker: worker)
        #expect(await cache.image(site) == nil)
        #expect(await loader.calls.isEmpty); #expect(state.counts == (0, 0))
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(await cache.image(site) == nil)
        #expect(await loader.calls.isEmpty); #expect(state.counts == (0, 0))
        now += 60
        let image = try #require(await cache.image(site))
        #expect(image.width == 2 && state.counts == (1, 1))
        #expect(await loader.calls == [site])
        await registry.disable(.mediaPreviews)
        #expect(cache.cached(site) === image, "Completed pixels are not erased merely by later health")
        #expect(await cache.image(site) === image)
        cache.cancel(); await registry.shutdown()
    }

    @Test func sharedWaitersKeepOriginalStampAcrossHeldLoaderAndRecovery() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let site = url("shared"), state = FaviconAuthorityNative(), worker = worker(state)
        let loader = FaviconAuthorityLoader(held: [site])
        var now = Date(timeIntervalSinceReferenceDate: 100), joined = 0
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, clock: { now }, worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let a = Task { await cache.image(site) }
        await wait { await loader.calls.count == 1 }
        let b = Task { joined += 1; return await cache.image(site) }
        await wait { joined == 1 }
        a.cancel()
        await registry.disable(.mediaPreviews)
        do { try await registry.start(.mediaPreviews) }
        catch { await loader.release(); _ = await a.value; _ = await b.value; throw error }
        let c = Task { joined += 1; return await cache.image(site) }
        await wait { joined == 2 }
        await loader.release()
        #expect(await a.value == nil); #expect(await b.value == nil); #expect(await c.value == nil)
        #expect(state.counts == (0, 0) && cache.cached(site) == nil)
        #expect(await loader.calls == [site])
        #expect(await cache.image(site) == nil, "Retirement retains the normal negative cache")
        now += 60
        #expect(await cache.image(site) != nil)
        #expect(state.counts == (1, 1)); #expect(await loader.calls == [site, site])
        cache.cancel(); await registry.shutdown()
    }

    @Test func canceledUncooperativeLoadersKeepPendingCapacityUntilCollected() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = url("one"), two = url("two"), three = url("three")
        let loader = FaviconAuthorityLoader(held: [one, two]), state = FaviconAuthorityNative(), worker = worker(state)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let a = Task { await cache.image(one) }, b = Task { await cache.image(two) }
        await wait { await loader.calls.count == 2 }
        a.cancel(); b.cancel(); cache.cancel()
        #expect(await cache.image(three) == nil)
        #expect(await loader.calls.count == 2); #expect(state.counts == (0, 0))
        await loader.release(); #expect(await a.value == nil); #expect(await b.value == nil)
        #expect(await cache.image(three) != nil)
        #expect(await loader.calls.count == 3); #expect(state.counts == (1, 1))
        cache.cancel(); await registry.shutdown()
    }

    @Test func canceledUncooperativeNativeKeepsSlotsAndCannotCacheLatePixels() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = FaviconAuthorityNative(held: true), worker = worker(state), loader = FaviconAuthorityLoader()
        defer { state.release() }
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let one = url("one"), two = url("two"), three = url("three")
        let a = Task { await cache.image(one) }, b = Task { await cache.image(two) }
        await wait { state.counts.0 == 2 }; a.cancel(); b.cancel(); cache.cancel()
        #expect(worker.activeCount == 2 && state.counts == (2, 0))
        #expect(await cache.image(three) == nil); #expect(await loader.calls.count == 2)
        state.release(); #expect(await a.value == nil); #expect(await b.value == nil)
        #expect(worker.activeCount == 0 && state.counts == (2, 2))
        #expect(cache.cached(one) == nil && cache.cached(two) == nil)
        #expect(await cache.image(three) != nil); #expect(state.counts == (3, 3))
        cache.cancel(); await registry.shutdown()
    }

    @Test func originalNativeCheckAfterFinalAccessCallbackPreventsCachePublication() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = FaviconAuthorityNative(), worker = worker(state), loader = FaviconAuthorityLoader(), site = url("terminal")
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        var armed = true
        let scope = AskImagePresentationScope()
        let access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: {
            if armed && state.counts.1 == 1 {
                #expect(worker.activeCount == 0 && worker.permits(worker.authorization()), "Successful native collection precedes revocation")
                armed = false; module.module.supervisor.admission.setEnabled(false)
            }
            return true
        })
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker)
        #expect(await cache.image(site, access: access) == nil)
        #expect(!armed && state.counts == (1, 1) && cache.cached(site, access: access) == nil)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == (1, 1)); #expect(await loader.calls == [site])
        cache.cancel(); await registry.shutdown()
    }

    @Test func scopeReplacementKeepsFreshDefaultResultAfterOldLoaderReturns() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = url("old"), fresh = url("fresh"), loader = FaviconAuthorityLoader(held: [old])
        let state = FaviconAuthorityNative(), worker = worker(state), scope = AskImagePresentationScope()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let cache = AskBrowserFaviconCache(loader: { await loader.load($0) }, worker: worker)
        let oldAccess = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let task = Task { await cache.image(old, access: oldAccess) }
        await wait { await loader.calls.count == 1 }; scope.invalidate()
        let newAccess = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let image = await cache.image(fresh, access: newAccess)
        #expect(image != nil)
        await loader.release(); #expect(await task.value == nil)
        #expect(cache.cached(fresh, access: newAccess) === image && cache.cached(old, access: oldAccess) == nil)
        #expect(state.counts == (1, 1))
        cache.cancel(); await registry.shutdown()
    }

    @Test func customActorDecoderRemainsIndependentAndInputRefusalsKeepBounds() async throws {
        let state = FaviconAuthorityNative(), worker = worker(state), custom = FaviconIndependentDecoder()
        let cache = AskBrowserFaviconCache(loader: { _ in Data([1]) }, worker: worker, decode: { _ in await custom.decode() })
        #expect(await cache.image(url("custom")) != nil)
        #expect(await custom.count == 1); #expect(state.counts == (0, 0))
        for bytes in [Data(), Data(count: 262_145)] {
            let invalid = AskBrowserFaviconCache(loader: { _ in bytes }, worker: worker, decode: { _ in Issue.record("Invalid input decoded"); return await custom.decode() })
            #expect(await invalid.image(url("invalid")) == nil); invalid.cancel()
        }
        let canceled = Task { withUnsafeCurrentTask { $0?.cancel() }; return await cache.image(url("canceled")) }
        #expect(await canceled.value == nil); #expect(await custom.count == 1)
        cache.cancel()
    }
}
