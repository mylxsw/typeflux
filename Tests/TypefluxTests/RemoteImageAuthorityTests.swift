import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class RemoteAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, sends = 0, custom = 0
    var counts: [Int] { lock.withLock { [runs, sends, custom] } }
    func run() { lock.withLock { runs += 1 } }
    func send() -> Int { lock.withLock { sends += 1; return sends } }
    func decoded() { lock.withLock { custom += 1 } }
}
private final class RemoteAuthorityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, started = 0
    var count: Int { condition.withLock { started } }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        started += 1
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private struct RemoteAuthorityTransport: AskImageTransport {
    let read: @Sendable (URLRequest, Int) async throws -> Data
    func send(_ request: URLRequest, limit: Int) async throws -> Data { try await read(request, limit) }
}

@Suite("Remote image original presentation authority", .serialized, .exclusiveUIState)
@MainActor struct RemoteImageAuthorityTests {
    private let asset = AskGeneratedImage(assetId: "original", url: "https://private.invalid/original?signed=fixture")
    private func worker(_ state: RemoteAuthorityState, held: RemoteAuthorityGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run(); held?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw MediaFailure.unavailable }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            try file.write(contentsOf: Data(repeating: 128, count: 16))
            var response = MediaResponse(id: request.id)
            response.preview = .init(rasters: [.init(width: 2, height: 2)])
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func transport(_ state: RemoteAuthorityState, held: RemoteAuthorityGate? = nil,
                           onlyFirst: Bool = false) -> RemoteAuthorityTransport {
        .init { request, limit in
            let number = state.send()
            #expect(request.httpMethod == "GET" && request.timeoutInterval == 15 && limit == AskRemoteImageLoader.maximumBytes)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if !onlyFirst || number == 1 { held?.wait() }
            return Data([1, 2, 3])
        }
    }
    private func access(_ scope: AskRemoteImageScope) -> AskRemoteImageAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func heldResponseCannotAdoptRecoveredNativeGeneration() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RemoteAuthorityState(), worker = worker(state), gate = RemoteAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let loader = AskRemoteImageLoader(transport: transport(state, held: gate, onlyFirst: true), worker: worker)
        let task = Task { try await loader.load(asset) }
        await wait { gate.count == 1 }; #expect(worker.activeCount == 0)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == [0, 1, 0])
        gate.release()
        do { _ = try await task.value; Issue.record("Old response adopted recovery") } catch {}
        #expect(state.counts == [0, 1, 0])
        let fresh = try await loader.load(asset)
        #expect(fresh.images.first?.width == 2 && fresh.images.first?.height == 2 && state.counts == [1, 2, 0])
        #expect(asset.assetId == "original" && asset.safeURL?.query == "signed=fixture")
        await registry.shutdown()
    }

    @Test func preReadyModelKeepsLinkFallbackAndNeedsExplicitFreshLoad() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RemoteAuthorityState(), worker = worker(state)
        let loader = AskRemoteImageLoader(transport: transport(state), worker: worker)
        let scope = AskRemoteImageScope(), model = AskRemoteImageModel(loader: loader)
        await model.load(asset, access: access(scope))
        #expect(model.image == nil && model.unavailable && state.counts == [0, 0, 0])
        #expect(AskRemoteImageLoader.eligible(asset) == asset.safeURL)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(model.image == nil && model.unavailable && state.counts == [0, 0, 0])
        await model.load(asset, access: access(scope))
        #expect(model.image != nil && !model.unavailable && state.counts == [1, 1, 0])
        scope.invalidate(); #expect(model.image == nil)
        await registry.shutdown()
    }

    @Test func retainedQueuedAuthorizationRejectsPreReadyRetiredAndForeignStamps() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RemoteAuthorityState(), worker = worker(state)
        let loader = AskRemoteImageLoader(transport: transport(state), worker: worker)
        let preReady = try #require(loader.authorization())
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let old = try #require(loader.authorization())
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        for stamp in [preReady, old, foreign] {
            do { _ = try await loader.load(asset, authorization: stamp); Issue.record("Queued stamp upgraded") } catch {}
            do { _ = try await AskRemoteImageLoader.decodePixels(Data([1]), worker: worker, authorization: stamp); Issue.record("Direct old decoder upgraded") } catch {}
        }
        #expect(state.counts == [0, 0, 0])
        let pixels = try await AskRemoteImageLoader.decodePixels(Data([1]), worker: worker)
        #expect(pixels.images.count == 1 && state.counts == [1, 0, 0])
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.load(asset)
        }
        do { _ = try await canceled.value; Issue.record("Pre-canceled response") } catch is CancellationError {}
        #expect(state.counts == [1, 0, 0])
        await registry.shutdown()
    }

    @Test func canceledUncooperativeResponsesKeepBothDownloadSlotsUntilReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RemoteAuthorityState(), worker = worker(state), gate = RemoteAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let loader = AskRemoteImageLoader(transport: transport(state, held: gate), worker: worker)
        let a = Task { try await loader.load(asset) }, b = Task { try await loader.load(asset) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        do { _ = try await loader.load(asset); Issue.record("Occupied downloads released early") } catch {}
        #expect(state.counts == [0, 2, 0])
        gate.release()
        for task in [a, b] {
            do { _ = try await task.value; Issue.record("Late canceled response") } catch is CancellationError {}
        }
        #expect(worker.activeCount == 0 && state.counts == [0, 2, 0])
        _ = try await loader.load(asset)
        #expect(state.counts == [1, 3, 0])
        await registry.shutdown()
    }

    @Test func canceledUncooperativeNativeWorkRetainsSlotsAndRejectsLatePixels() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RemoteAuthorityState(), gate = RemoteAuthorityGate(), worker = worker(state, held: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let loader = AskRemoteImageLoader(transport: transport(state), worker: worker)
        let a = Task { try await loader.load(asset) }, b = Task { try await loader.load(asset) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        #expect(worker.activeCount == 2)
        do { _ = try await loader.load(asset); Issue.record("Occupied native loader released") } catch {}
        #expect(state.counts == [2, 2, 0])
        gate.release()
        for task in [a, b] { do { _ = try await task.value; Issue.record("Late pixels") } catch {} }
        #expect(worker.activeCount == 0)
        _ = try await loader.load(asset)
        #expect(state.counts == [3, 3, 0])
        await registry.shutdown()
    }

    @Test func actualModelScopeReplacementKeepsNewPixelsAfterOldResponseCollection() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RemoteAuthorityState(), worker = worker(state), gate = RemoteAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskRemoteImageScope(), oldAccess = access(scope)
        let loader = AskRemoteImageLoader(transport: transport(state, held: gate, onlyFirst: true), worker: worker)
        let model = AskRemoteImageModel(loader: loader, budget: AskToolPixelBudget(limit: 2 * 1600 * 1600 * 4))
        let old = Task { await model.load(asset, access: oldAccess) }
        await wait { gate.count == 1 }; scope.invalidate()
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        let fresh = AskGeneratedImage(assetId: "fresh", url: "https://private.invalid/fresh")
        await model.load(fresh, access: access(scope))
        let snapshot = try #require(model.image)
        #expect(model.source == fresh && !oldAccess.allows() && state.counts == [1, 2, 0])
        gate.release(); await old.value
        #expect(model.image === snapshot && model.source == fresh && !model.unavailable && state.counts == [1, 2, 0])
        scope.invalidate(); #expect(model.image == nil)
        await registry.shutdown()
    }

    @Test func customDecoderRemainsIndependentOfUnreadyNativeWorker() async throws {
        let state = RemoteAuthorityState(), worker = worker(state)
        let pixels = AskAttachmentFixture.image(width: 2, height: 2)
        let loader = AskRemoteImageLoader(transport: transport(state), decode: { bytes in
            #expect(bytes == Data([1, 2, 3])); state.decoded()
            return .init(images: [pixels], numbers: [], pages: 0)
        }, worker: worker)
        #expect(loader.authorization() == nil)
        let result = try await loader.load(asset)
        #expect(result.images.first === pixels && state.counts == [0, 1, 1])
    }

    @Test func finalModelAdmissionRejectsRevocationAfterPixelsHaveReturned() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RemoteAuthorityState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskRemoteImageScope()
        var checks = 0
        let access = AskRemoteImageAccess(scope: scope, epoch: scope.epoch, authorize: {
            checks += 1
            if checks == 2 { worker.preventNewWork() }
            return true
        })
        let model = AskRemoteImageModel(loader: .init(transport: transport(state), worker: worker))
        await model.load(asset, access: access)
        #expect(checks >= 2 && worker.activeCount == 0 && state.counts == [1, 1, 0])
        #expect(model.image == nil && model.unavailable && AskRemoteImageLoader.eligible(asset) != nil)
        await registry.shutdown()
    }
}
