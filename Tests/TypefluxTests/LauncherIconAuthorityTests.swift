import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class LauncherAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, valid = 0
    private var firstClock: Int?
    private var reply: (@Sendable () -> Void)?
    var counts: [Int] { lock.withLock { [runs, valid] } }
    var clockTask: Int? { lock.withLock { firstClock } }
    func clock() -> TimeInterval {
        let task = withUnsafeCurrentTask { $0?.hashValue }
        lock.withLock { if firstClock == nil { firstClock = task } }
        return ProcessInfo.processInfo.systemUptime
    }
    func run() -> Int { lock.withLock { runs += 1; return runs } }
    func finish() { let action = lock.withLock { valid += 1; return reply }; action?() }
    func afterReply(_ action: (@Sendable () -> Void)?) { lock.withLock { reply = action } }
}
private final class LauncherAuthorityGate: @unchecked Sendable {
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
private actor IndependentLauncherDecoder {
    private(set) var calls = 0
    func decode() -> AskFilePreviewPDF.Result {
        calls += 1
        return .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
}

@Suite("Launcher icon accepted native authority", .exclusiveUIState)
@MainActor struct LauncherIconAuthorityTests {
    private let app = MediaNativeIcon(kind: .application, value: "private.fixture.application")
    private func worker(_ state: LauncherAuthorityState, managed: Bool = true,
                        gate: LauncherAuthorityGate? = nil, firstOnly: Bool = false) -> MediaWorker {
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

    @Test func defaultPendingBindsInAcceptedCallerBeforeItsTask() async throws {
        let state = LauncherAuthorityState(), worker = worker(state, managed: false)
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        let caller = withUnsafeCurrentTask { $0?.hashValue }
        #expect(caller != nil && state.clockTask == nil)
        let result = try await cache.load(app)
        #expect(state.clockTask == caller && state.counts == [1, 1])
        #expect(cache.cached(app)?.images.first === result.images.first)
        cache.clear(); await worker.shutdown()
    }

    @Test func preReadyCanceledAndForwardedOldRequestsDoNotReplayOrCreateNativeWork() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = LauncherAuthorityState(), worker = worker(state), old = worker.authorization()
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await cache.load(app); Issue.record("Canceled cache entry") } catch {}
        }
        await canceled.value
        do { _ = try await cache.load(app); Issue.record("Pre-ready cache") } catch {}
        #expect(state.counts == [0, 0] && cache.cached(app) == nil)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(state.counts == [0, 0])
        do { _ = try await cache.load(app, authorization: old); Issue.record("Old outer request upgraded") } catch {}
        #expect(state.counts == [0, 0])
        _ = try await cache.load(app)
        #expect(state.counts == [1, 1] && cache.cached(app) != nil)
        cache.clear(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func prefetchBindsBeforeImmediateLookupAndQueuedTask(privateFile: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.txt"), bytes = Data([1, 2, 3]); try bytes.write(to: file)
        let state = LauncherAuthorityState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let admission = module.module.supervisor.admission, revision = Date(timeIntervalSince1970: 1_000)
        let icon = privateFile ? MediaNativeIcon(kind: .file, value: file.path) : app
        let hit = AskFileHit(path: file.path, name: "private.txt", kind: .file, modified: revision, score: 1)
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in
            // This existing synchronous source callback makes availability current BEFORE the Task can start.
            admission.setEnabled(true); return nil
        }, worker: worker)
        admission.setEnabled(false)
        let old = privateFile ? cache.prefetchFiles([hit]) : cache.prefetch([icon])
        #expect(old.count == 1 && worker.permits(worker.authorization()))
        for task in old { await task.value }
        #expect(state.counts == [0, 0] && cache.cached(icon, revision: privateFile ? revision : nil) == nil)
        let fresh = privateFile ? cache.prefetchFiles([hit]) : cache.prefetch([icon])
        for task in fresh { await task.value }
        #expect(state.counts == [1, 1] && cache.cached(icon, revision: privateFile ? revision : nil) != nil)
        #expect(try Data(contentsOf: file) == bytes)
        for task in cache.cancelPrefetch() { await task.value }
        cache.clear(); await registry.shutdown()
    }

    @Test func sharedPendingKeepsOneNativeCallWhenOneClientCancels() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = LauncherAuthorityState(), gate = LauncherAuthorityGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        let first = Task { try await cache.load(app) }
        await wait { gate.count == 1 }
        var entered = false
        let second = Task { entered = true; return try await cache.load(app) }
        await wait { entered }; first.cancel()
        #expect(state.counts == [1, 0] && worker.activeCount == 1)
        gate.release()
        do { _ = try await first.value; Issue.record("Canceled client returned pixels") } catch {}
        let result = try await second.value
        #expect(state.counts == [1, 1] && cache.cached(app)?.images.first === result.images.first)
        module.module.supervisor.admission.setEnabled(false)
        _ = try await cache.load(app)
        #expect(state.counts == [1, 1], "Completed cache is independent of later health")
        cache.clear(); await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func canceledUncooperativeRequestsRetainNativeCapacityUntilReturn(privateFiles: Bool) async throws {
        let state = LauncherAuthorityState(), gate = LauncherAuthorityGate(), worker = worker(state, managed: false, gate: gate)
        defer { gate.release() }
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        let revision: Date? = privateFiles ? Date(timeIntervalSince1970: 1_000) : nil
        let one = MediaNativeIcon(kind: privateFiles ? .file : .application, value: privateFiles ? "/private/one" : "private.one")
        let two = MediaNativeIcon(kind: privateFiles ? .file : .application, value: privateFiles ? "/private/two" : "private.two")
        let thirdIcon = MediaNativeIcon(kind: privateFiles ? .file : .application, value: privateFiles ? "/private/three" : "private.three")
        let a = Task { try await cache.load(one, revision: revision) }
        let b = Task { try await cache.load(two, revision: revision) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        if privateFiles { cache.clearFiles() } else { cache.clear() }
        var entered = false
        let third = Task { entered = true; return try await cache.load(thirdIcon, revision: revision) }
        await wait { entered }; third.cancel()
        do { _ = try await third.value; Issue.record("Canceled queued cache client") } catch {}
        #expect(state.counts == [2, 0] && worker.activeCount == 2)
        gate.release()
        for task in [a, b] { do { _ = try await task.value; Issue.record("Canceled late cache image") } catch {} }
        #expect(worker.activeCount == 0 && state.counts == [2, 2])
        #expect(cache.cached(one, revision: revision) == nil && cache.cached(two, revision: revision) == nil)
        _ = try await cache.load(thirdIcon, revision: revision)
        #expect(state.counts == [3, 3])
        cache.clear(); await worker.shutdown()
    }

    @Test func oldCompletionAfterClearCannotReplaceFreshPrivatePixels() async throws {
        let state = LauncherAuthorityState(), gate = LauncherAuthorityGate(), worker = worker(state, managed: false, gate: gate, firstOnly: true)
        defer { gate.release() }
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        let icon = MediaNativeIcon(kind: .file, value: "/private/original"), revision = Date(timeIntervalSince1970: 1_000)
        let old = Task { try await cache.load(icon, revision: revision) }
        await wait { gate.count == 1 }; cache.clearFiles()
        let fresh = try await cache.load(icon, revision: revision)
        #expect(worker.activeCount == 1 && cache.cached(icon, revision: revision)?.images.first === fresh.images.first)
        gate.release()
        do { _ = try await old.value; Issue.record("Retired private cache result") } catch {}
        #expect(cache.cached(icon, revision: revision)?.images.first === fresh.images.first && state.counts == [2, 2])
        cache.clear(); await worker.shutdown()
    }

    @Test func validReplyRevocationCannotCacheAndFreshExplicitRecoveryWorks() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = LauncherAuthorityState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let original = worker.authorization(), admission = module.module.supervisor.admission
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        state.afterReply {
            #expect(state.counts == [1, 1] && worker.permits(original)); admission.setEnabled(false)
        }
        do { _ = try await cache.load(app); Issue.record("Retired valid native reply cached") } catch {}
        #expect(cache.cached(app) == nil && state.counts == [1, 1] && worker.activeCount == 0)
        state.afterReply(nil)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == [1, 1])
        _ = try await cache.load(app)
        #expect(cache.cached(app) != nil && state.counts == [2, 2])
        cache.clear(); await registry.shutdown()
    }

    @Test func canceledPrefetchReturnsHandlesThatCollectActualNativeReturn() async throws {
        let state = LauncherAuthorityState(), gate = LauncherAuthorityGate(), worker = worker(state, managed: false, gate: gate)
        defer { gate.release() }
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker)
        let accepted = cache.prefetch([app])
        await wait { gate.count == 1 }
        let retiring = cache.cancelPrefetch()
        #expect(accepted.count == 1 && retiring.count == 1 && worker.activeCount == 1 && state.counts == [1, 0])
        gate.release()
        for task in accepted + retiring { await task.value }
        #expect(worker.activeCount == 0 && state.counts == [1, 1] && cache.cached(app) == nil)
        _ = try await cache.load(app)
        #expect(cache.cached(app) != nil && state.counts == [2, 2])
        cache.clear(); await worker.shutdown()
    }

    @Test func customActorAndImmediateMetadataRemainIndependentOfUnreadyNativeWorker() async throws {
        let state = LauncherAuthorityState(), worker = worker(state), custom = IndependentLauncherDecoder()
        let cache = AskLauncherIconCache(immediateLookup: { _, _ in nil }, worker: worker, decode: { _ in await custom.decode() })
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        _ = try await cache.load(app, authorization: foreign)
        let tasks = cache.prefetchFiles([AskFileHit(path: "/private/fixture", name: "fixture", kind: .file,
                                                  modified: Date(timeIntervalSince1970: 1_000), score: 1)])
        for task in tasks { await task.value }
        #expect(await custom.calls == 2)
        #expect(state.counts == [0, 0] && state.clockTask == nil)
        let pixels = AskAttachmentFixture.image(width: 2, height: 2)
        let immediate = AskLauncherIconCache(immediateLookup: { _, _ in NSImage(cgImage: pixels, size: .init(width: 2, height: 2)) }, worker: worker)
        let metadata = immediate.prefetch([app])
        #expect(metadata.isEmpty && immediate.cached(app) != nil && state.counts == [0, 0])
        for task in cache.cancelPrefetch() { await task.value }
        cache.clear(); immediate.clear(); await worker.shutdown()
    }
}
