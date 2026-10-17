import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class LookupOwnershipState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, valid = 0
    var counts: [Int] { lock.withLock { [runs, valid] } }
    func run() -> Int { lock.withLock { runs += 1; return runs } }
    func finish() { lock.withLock { valid += 1 } }
}
private final class LookupOwnershipGate: @unchecked Sendable {
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
@Suite("Launcher synchronous lookup ownership", .exclusiveUIState)
@MainActor struct LauncherLookupOwnershipTests {
    private let app = MediaNativeIcon(kind: .application, value: "private.fixture.application")
    private func worker(_ state: LookupOwnershipState, managed: Bool = false,
                        gate: LookupOwnershipGate? = nil, firstOnly: Bool = false) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: managed,
            run: { p, _ in
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

    private let revision = Date(timeIntervalSince1970: 1_000)
    private let file = MediaNativeIcon(kind: .file, value: "/private/lookup-fixture")
    private func image() -> NSImage {
        NSImage(cgImage: AskAttachmentFixture.image(width: 2, height: 2), size: .init(width: 2, height: 2))
    }
    private func hit(_ path: String) -> AskFileHit {
        .init(path: path, name: "private", kind: .file, modified: revision, score: 1)
    }

    @Test(arguments: ["clear", "files", "task"])
    func retiredImmediateLookupCannotPublishAndFreshExplicitLookupWorks(mode: String) async {
        let pixels = image(); var armed = true, calls = 0
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in
            calls += 1
            if armed {
                armed = false
                if mode == "clear" { target?.clear() }
                else if mode == "files" { target?.clearFiles() }
                else { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return pixels
        })
        target = cache
        let old = Task { cache.immediate(file, revision: revision) }
        #expect(await old.value == nil)
        #expect(cache.cached(file, revision: revision) == nil && calls == 1)
        let fresh = cache.immediate(file, revision: revision)
        #expect(fresh?.images.first?.width == 56 && calls == 2)
        #expect(cache.cached(file, revision: revision)?.images.first === fresh?.images.first)
        cache.clear()
    }

    @Test(arguments: [false, true])
    func nestedFreshMetadataSurvivesLateOldLookupReturn(clear: Bool) async {
        let oldImage = image(), freshImage = image(); var armed = true
        var fresh: AskFilePreviewPDF.Result?
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(immediateLookup: { icon, _ in
            if armed {
                armed = false; if clear { target?.clear() }
                fresh = target?.immediate(icon)
                return oldImage
            }
            return freshImage
        })
        target = cache
        let returned = cache.immediate(app)
        #expect((returned == nil) == clear)
        if !clear { #expect(returned?.images.first === fresh?.images.first) }
        #expect(fresh != nil && cache.cached(app)?.images.first === fresh?.images.first)
        cache.clear()
    }

    @Test func metadataNamespacesHealthBoundsAndCanceledCacheHitsRemainIndependent() async {
        let state = LookupOwnershipState(), worker = worker(state, managed: true), pixels = image()
        var calls = 0, clearFiles = true
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(fileCapacity: 1, immediateLookup: { _, _ in
            calls += 1; if clearFiles { target?.clearFiles() }; return pixels
        }, worker: worker)
        target = cache
        let application = cache.immediate(app)
        #expect(application != nil && state.counts == [0, 0])
        #expect(cache.immediate(file, revision: revision) == nil)
        clearFiles = false
        #expect(cache.immediate(file, revision: revision) != nil)
        let changed = revision.addingTimeInterval(1)
        #expect(cache.immediate(file, revision: changed) != nil)
        #expect(cache.cached(file, revision: revision) == nil)
        cache.clearFiles(); #expect(cache.cached(app)?.images.first === application?.images.first)
        worker.preventNewWork()
        let before = calls
        let canceledHit = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return cache.immediate(app)
        }
        #expect(await canceledHit.value?.images.first === application?.images.first)
        let canceledMiss = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return cache.immediate(file, revision: revision)
        }
        #expect(await canceledMiss.value == nil && calls == before)
        #expect(cache.immediate(.init(kind: .application, value: "")) == nil)
        #expect(cache.immediate(.init(kind: .type, value: "public.data")) == nil)
        #expect(cache.immediate(file) == nil && calls == before && state.counts == [0, 0])
        cache.clear(); await worker.shutdown()
    }

    @Test(arguments: ["clear", "files", "cancel", "task"])
    func retiredPrefetchLookupCannotInterpretRetirementAsNativeMiss(mode: String) async throws {
        let state = LookupOwnershipState(), worker = worker(state); var armed = true, lookups = 0
        var canceled: [Task<Void, Never>] = []
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in
            lookups += 1
            if armed {
                armed = false
                if mode == "clear" { target?.clear() }
                else if mode == "files" { target?.clearFiles() }
                else if mode == "cancel" { canceled = target?.cancelPrefetch() ?? [] }
                else { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return nil
        }, worker: worker)
        target = cache
        let old = Task { cache.prefetchFiles([hit(file.value)]) }
        let handles = await old.value
        for task in handles + canceled { await task.value }
        #expect(handles.isEmpty && lookups == 1 && state.counts == [0, 0])
        let fresh = cache.prefetchFiles([hit(file.value)])
        #expect(fresh.count == 1)
        for task in fresh { await task.value }
        #expect(cache.cached(file, revision: revision) != nil && state.counts == [1, 1])
        cache.clear(); await worker.shutdown()
    }

    @Test(arguments: [false, true])
    func nestedPrefetchKeepsLatestWantedSetAndCoalescesCompatibleWork(same: Bool) async throws {
        let state = LookupOwnershipState(), worker = worker(state)
        let next = same ? app : MediaNativeIcon(kind: .application, value: "private.next")
        var armed = true, nested: [Task<Void, Never>] = []
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in
            if armed { armed = false; nested = target?.prefetch([next]) ?? [] }
            return nil
        }, worker: worker)
        target = cache
        let old = cache.prefetch([app])
        #expect(old.count == (same ? 1 : 0) && nested.count == 1)
        for task in old + nested { await task.value }
        #expect(state.counts == [1, 1] && cache.cached(next) != nil)
        if !same { #expect(cache.cached(app) == nil) }
        cache.clear(); await worker.shutdown()
    }

    @Test func callbackClearStillReturnsTasksAcceptedEarlierInSameLoop() async throws {
        let state = LookupOwnershipState(), worker = worker(state)
        let second = MediaNativeIcon(kind: .application, value: "private.second")
        var armed = true
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(immediateLookup: { icon, _ in
            if icon == second && armed { armed = false; target?.clear() }
            return nil
        }, worker: worker)
        target = cache
        let observed = cache.prefetch([app, second])
        #expect(observed.count == 1 && observed[0].isCancelled)
        for task in observed { await task.value }
        #expect(state.counts == [0, 0] && cache.cached(app) == nil && cache.cached(second) == nil)
        let fresh = cache.prefetch([app])
        for task in fresh { await task.value }
        #expect(state.counts == [1, 1] && cache.cached(app) != nil)
        cache.clear(); await worker.shutdown()
    }

    @Test func callbackClearRetainsObservedRunningHandleUntilNativeActuallyReturns() async throws {
        let state = LookupOwnershipState(), gate = LookupOwnershipGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let second = MediaNativeIcon(kind: .application, value: "private.second")
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(immediateLookup: { icon, _ in
            if icon == second { target?.clear() }
            return nil
        }, worker: worker)
        target = cache
        let first = cache.prefetch([app])
        await wait { gate.count == 1 }
        let observed = cache.prefetch([app, second])
        #expect(first.count == 1 && observed.count == 1 && worker.activeCount == 1 && state.counts == [1, 0])
        gate.release()
        for task in first + observed { await task.value }
        #expect(state.counts == [1, 1] && worker.activeCount == 0 && cache.cached(app) == nil)
        let fresh = cache.prefetch([app])
        for task in fresh { await task.value }
        #expect(state.counts == [2, 2] && cache.cached(app) != nil)
        cache.clear(); await worker.shutdown()
    }

    @Test func precanceledPrefetchDoesNotRetireExistingOwnedRequest() async throws {
        let state = LookupOwnershipState(), gate = LookupOwnershipGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        var lookups = 0
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in lookups += 1; return nil }, worker: worker)
        let first = cache.prefetch([app]); await wait { gate.count == 1 }
        let before = lookups
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return cache.prefetch([.init(kind: .application, value: "private.other")])
        }
        let refused = await canceled.value
        #expect(refused.isEmpty && lookups == before && worker.activeCount == 1)
        gate.release(); for task in first { await task.value }
        #expect(state.counts == [1, 1] && cache.cached(app) != nil)
        cache.clear(); await worker.shutdown()
    }

    @Test func fileClearDoesNotRetireApplicationPrefetchButDoesRetireFileQueryForBundle() async throws {
        let state = LookupOwnershipState(), worker = worker(state)
        weak var target: AskLauncherIconCache?
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in target?.clearFiles(); return nil }, worker: worker)
        target = cache
        let application = cache.prefetch([app])
        for task in application { await task.value }
        #expect(application.count == 1 && state.counts == [1, 1] && cache.cached(app) != nil)
        let bundle = MediaNativeIcon(kind: .file, value: "/private/Fixture.app")
        let retiredFileQuery = cache.prefetchFiles([hit(bundle.value)])
        for task in retiredFileQuery { await task.value }
        #expect(retiredFileQuery.isEmpty && state.counts == [1, 1] && cache.cached(bundle) == nil)
        cache.clear(); await worker.shutdown()
    }
}
