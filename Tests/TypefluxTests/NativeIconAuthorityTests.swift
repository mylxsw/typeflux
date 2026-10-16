import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class NativeAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, valid = 0, clocks = 0, watchedClocks = 0
    private var watched: Int?
    private var reply: (@Sendable () -> Void)?
    var counts: [Int] { lock.withLock { [runs, valid] } }
    var clockCount: Int { lock.withLock { clocks } }
    var watchedCount: Int { lock.withLock { watchedClocks } }
    func watch(_ task: Int?) { lock.withLock { watched = task; watchedClocks = 0 } }
    func clock() -> TimeInterval {
        let task = withUnsafeCurrentTask { $0?.hashValue }
        lock.withLock { clocks += 1; if task != nil && task == watched { watchedClocks += 1 } }
        return ProcessInfo.processInfo.systemUptime
    }
    func run() { lock.withLock { runs += 1 } }
    func finish() { let action = lock.withLock { valid += 1; return reply }; action?() }
    func afterReply(_ action: (@Sendable () -> Void)?) { lock.withLock { reply = action } }
}
private final class NativeAuthorityGate: @unchecked Sendable {
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

@Suite("Native icon original admission authority", .exclusiveUIState)
@MainActor struct NativeIconAuthorityTests {
    private let icon = MediaNativeIcon(kind: .application, value: "private.fixture.application")
    private func worker(_ state: NativeAuthorityState, managed: Bool = true,
                        gate: NativeAuthorityGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: managed,
            uptime: { state.clock() }, run: { p, _ in
                state.run(); gate?.wait()
                let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
                try request.validate()
                #expect(request.operation == .nativeIcon || request.operation == .previewImage)
                if request.operation == .nativeIcon { #expect(request.icon != nil && request.preview?.imageType == nil) }
                let edge = min(2, request.preview!.width)
                let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw MediaFailure.unavailable }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(repeating: 128, count: edge * edge * 4))
                var response = MediaResponse(id: request.id)
                response.preview = .init(rasters: [.init(width: edge, height: edge)])
                response.preview?.imageType = request.preview?.imageType
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

    @Test func unavailableCanceledAndOriginalStampsRejectBeforeNativeAndFacade() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeAuthorityState(), worker = worker(state), preReady = worker.authorization()
        do { _ = try await AskFinderIcon.decode(icon, worker: worker); Issue.record("Pre-ready native lookup") } catch {}
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await AskFinderIcon.decode(icon, worker: worker); Issue.record("Canceled native lookup") }
            catch { #expect(error is CancellationError) }
        }
        await canceled.value
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let retired = worker.authorization()
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        for stamp in [preReady, retired, foreign] {
            do { _ = try await AskFinderIcon.decode(icon, worker: worker, authorization: stamp); Issue.record("Old icon stamp upgraded") } catch {}
            do { _ = try MediaPreviewDisplay.renderIcon(icon, edge: 56, cancellation: AskSearchCancellation(), worker: worker,
                                                       authorization: stamp); Issue.record("Facade lost original stamp") } catch {}
        }
        #expect(state.counts == [0, 0])
        for edge in [1, 56, 112] {
            let result = try await AskFinderIcon.decode(icon, edge: edge, worker: worker)
            #expect(result.images.count == 1 && result.images[0].width == min(edge, 2))
        }
        #expect(state.counts == [3, 3] && worker.activeCount == 0)
        await registry.shutdown()
    }

    @Test func defaultQueuedRequestCannotAdoptLaterWorkerBindingAndRecovery() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let heldState = NativeAuthorityState(), gate = NativeAuthorityGate(), heldWorker = worker(heldState, managed: false, gate: gate)
        defer { gate.release() }
        let a = Task { try await AskFinderIcon.decode(icon, worker: heldWorker) }
        let b = Task { try await AskFinderIcon.decode(icon, worker: heldWorker) }
        await wait { gate.count == 2 }
        let state = NativeAuthorityState(), worker = worker(state, managed: false)
        let old = Task { try await AskFinderIcon.decode(icon, worker: worker) }
        // The existing read-only budget clock observes default capture BEFORE the occupied icon queue.
        await wait { state.clockCount >= 2 }; #expect(state.counts == [0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release(); _ = try await a.value; _ = try await b.value
        do { _ = try await old.value; Issue.record("Queued default icon adopted new lifecycle") } catch {}
        #expect(state.counts == [0, 0] && heldWorker.activeCount == 0)
        _ = try await AskFinderIcon.decode(icon, worker: worker)
        #expect(state.counts == [1, 1])
        await heldWorker.shutdown(); await registry.shutdown()
    }

    @Test func originalManagedRequestCannotUpgradeAcrossRecovery() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let heldState = NativeAuthorityState(), gate = NativeAuthorityGate(), heldWorker = worker(heldState, managed: false, gate: gate)
        defer { gate.release() }
        let a = Task { try await AskFinderIcon.decode(icon, worker: heldWorker) }
        let b = Task { try await AskFinderIcon.decode(icon, worker: heldWorker) }
        await wait { gate.count == 2 }
        let state = NativeAuthorityState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let original = worker.authorization()
        let old = Task { try await AskFinderIcon.decode(icon, worker: worker, authorization: original) }
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release(); _ = try await a.value; _ = try await b.value
        do { _ = try await old.value; Issue.record("Explicit managed request upgraded") } catch {}
        #expect(state.counts == [0, 0])
        _ = try await AskFinderIcon.decode(icon, worker: worker)
        #expect(state.counts == [1, 1])
        await heldWorker.shutdown(); await registry.shutdown()
    }

    @Test func canceledSharedWorkerWaitCannotDispatchAndRetainsOtherPhysicalWork() async throws {
        let state = NativeAuthorityState(), gate = NativeAuthorityGate(), worker = worker(state, managed: false, gate: gate)
        defer { gate.release() }
        let a = Task.detached { try worker.perform(.previewImage, input: .data(Data([1])), preview: .init(width: 56, height: 56),
                                                   isCancelled: { false }) { response, _ in response } }
        let b = Task.detached { try worker.perform(.previewImage, input: .data(Data([2])), preview: .init(width: 56, height: 56),
                                                   isCancelled: { false }) { response, _ in response } }
        await wait { gate.count == 2 }
        let waiting = Task {
            state.watch(withUnsafeCurrentTask { $0?.hashValue })
            return try await AskFinderIcon.decode(icon, worker: worker)
        }
        // More than one loop observed through the existing clock, without a scheduling hook.
        await wait { state.watchedCount >= 4 }; waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Canceled shared-worker waiter dispatched") } catch {}
        #expect(state.counts == [2, 0] && worker.activeCount == 2)
        gate.release(); _ = try await a.value; _ = try await b.value
        #expect(worker.activeCount == 0 && state.counts == [2, 2])
        _ = try await AskFinderIcon.decode(icon, worker: worker)
        #expect(state.counts == [3, 3])
        await worker.shutdown()
    }

    @Test func canceledNativeAndQueuedRequestsKeepCapacityUntilActualReturn() async throws {
        let state = NativeAuthorityState(), gate = NativeAuthorityGate(), worker = worker(state, managed: false, gate: gate)
        defer { gate.release() }
        let a = Task { try await AskFinderIcon.decode(icon, worker: worker) }
        let b = Task { try await AskFinderIcon.decode(icon, worker: worker) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        let queuedState = NativeAuthorityState(), queuedWorker = self.worker(queuedState, managed: false)
        let queued = Task { try await AskFinderIcon.decode(icon, worker: queuedWorker) }
        await wait { queuedState.clockCount >= 2 }; queued.cancel()
        do { _ = try await queued.value; Issue.record("Canceled icon queue entry") } catch {}
        #expect(state.counts == [2, 0] && worker.activeCount == 2 && queuedState.counts == [0, 0])
        gate.release()
        for task in [a, b] { do { _ = try await task.value; Issue.record("Canceled late icon") } catch {} }
        #expect(state.counts == [2, 2] && worker.activeCount == 0)
        _ = try await AskFinderIcon.decode(icon, worker: worker)
        #expect(state.counts == [3, 3])
        await worker.shutdown(); await queuedWorker.shutdown()
    }

    @Test func validNativeReplyRetiredBeforeReturnIsRejectedWithoutReplay() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeAuthorityState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let original = worker.authorization(), admission = module.module.supervisor.admission
        state.afterReply {
            #expect(worker.permits(original) && state.counts == [1, 1])
            admission.setEnabled(false)
        }
        do { _ = try await AskFinderIcon.decode(icon, worker: worker); Issue.record("Retired valid pixels") } catch {}
        #expect(state.counts == [1, 1] && worker.activeCount == 0)
        state.afterReply(nil)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == [1, 1])
        let result = try await AskFinderIcon.decode(icon, worker: worker)
        #expect(result.images.first?.width == 2 && state.counts == [2, 2])
        await registry.shutdown()
    }
}
