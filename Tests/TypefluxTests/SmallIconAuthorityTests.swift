import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class IconAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0, runs = 0, valid = 0
    private var afterReply: (@Sendable () -> Void)?
    var counts: (Int, Int, Int) { lock.withLock { (reads, runs, valid) } }
    func read() { lock.withLock { reads += 1 } }
    func run() { lock.withLock { runs += 1 } }
    func finish() { let action = lock.withLock { valid += 1; return afterReply }; action?() }
    func onReply(_ action: (@Sendable () -> Void)?) { lock.withLock { afterReply = action } }
}
private final class IconAuthorityGate: @unchecked Sendable {
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

@Suite("Small icon original preparation authority", .exclusiveUIState)
@MainActor struct SmallIconAuthorityTests {
    private func worker(_ state: IconAuthorityState, gate: IconAuthorityGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            #expect(request.operation == .previewImage && request.preview?.width == 56 && request.preview?.height == 56)
            let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw MediaFailure.unavailable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(repeating: 128, count: 16))
            var response = MediaResponse(id: request.id)
            response.preview = .init(rasters: [.init(width: 2, height: 2)])
            response.preview?.imageType = request.preview?.imageType
            try response.validate(for: request)
            state.finish()
            return .init(termination: .exited(0), exitCode: 0,
                         stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func unavailableCanceledAndRetiredRequestsCannotPrepareOrReplay() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = IconAuthorityState(), worker = worker(state), preReady = worker.authorization()
        let reader: AskSmallIconDecoder.InputReader = { input in state.read(); return try AskSmallIconDecoder.read(input) }
        do { _ = try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker, readInput: reader); Issue.record("Pre-ready work") }
        catch { #expect(error as? MediaFailure == .unavailable) }
        #expect(state.counts == (0, 0, 0))
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let retired = worker.authorization()
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        for stamp in [preReady, retired, foreign] {
            do { _ = try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker, authorization: stamp, readInput: reader); Issue.record("Old request upgraded") }
            catch { #expect(error as? MediaFailure == .unavailable) }
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker, readInput: reader); Issue.record("Canceled preparation") }
            catch { #expect(error is CancellationError) }
        }
        await canceled.value
        #expect(state.counts == (0, 0, 0), "Readiness must not replay an old input")
        let image = try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker, readInput: reader)
        #expect(image.width == 2 && state.counts == (1, 1, 1))
        await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func heldOriginalPreparationCannotAdoptRecoveredGeneration(file: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private-icon"), bytes = Data([1, 2, 3])
        try bytes.write(to: url)
        let input: AskSmallIconDecoder.Input = file ? .file(url) : .data(bytes)
        let state = IconAuthorityState(), gate = IconAuthorityGate(), worker = worker(state)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let old = Task { try await AskSmallIconDecoder.decode(input, worker: worker, readInput: {
            state.read(); gate.wait(); return try AskSmallIconDecoder.read($0)
        }) }
        await wait { gate.count == 1 }
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == (1, 0, 0))
        gate.release()
        do { _ = try await old.value; Issue.record("Prepared old input upgraded") } catch {}
        #expect(state.counts == (1, 0, 0))
        let fresh = try await AskSmallIconDecoder.decode(input, worker: worker)
        #expect(fresh.width == 2 && state.counts == (1, 1, 1))
        #expect(try Data(contentsOf: url) == bytes)
        await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func canceledPreparationsKeepBothSlotsUntilPhysicalReturn(file: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private-icon"), bytes = Data([1])
        try bytes.write(to: url)
        let input: AskSmallIconDecoder.Input = file ? .file(url) : .data(bytes)
        let state = IconAuthorityState(), gate = IconAuthorityGate(), worker = worker(state)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let reader: AskSmallIconDecoder.InputReader = { state.read(); gate.wait(); return try AskSmallIconDecoder.read($0) }
        let a = Task { try await AskSmallIconDecoder.decode(input, worker: worker, readInput: reader) }
        let b = Task { try await AskSmallIconDecoder.decode(input, worker: worker, readInput: reader) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        #expect(worker.activeCount == 0 && state.counts == (2, 0, 0))
        do { _ = try await AskSmallIconDecoder.decode(input, worker: worker, readInput: { _ in Issue.record("Early slot release"); return bytes }); Issue.record("Third slot") }
        catch {}
        gate.release(); _ = try? await a.value; _ = try? await b.value
        #expect(state.counts == (2, 0, 0))
        _ = try await AskSmallIconDecoder.decode(input, worker: worker)
        #expect(state.counts == (2, 1, 1) && worker.activeCount == 0)
        #expect(try Data(contentsOf: url) == bytes)
        await registry.shutdown()
    }

    @Test func canceledNativeCallsKeepCapacityAndRejectValidLateReplies() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = IconAuthorityState(), gate = IconAuthorityGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let a = Task { try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker) }
        let b = Task { try await AskSmallIconDecoder.decode(.data(Data([2])), worker: worker) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        #expect(worker.activeCount == 2)
        do { _ = try await AskSmallIconDecoder.decode(.data(Data([3])), worker: worker); Issue.record("Early native slot release") } catch {}
        #expect(state.counts.1 == 2)
        gate.release()
        for task in [a, b] {
            do { _ = try await task.value; Issue.record("Late canceled pixels") } catch {}
        }
        #expect(worker.activeCount == 0 && state.counts == (0, 2, 2))
        _ = try await AskSmallIconDecoder.decode(.data(Data([3])), worker: worker)
        #expect(state.counts == (0, 3, 3))
        await registry.shutdown()
    }

    @Test func validNativeReplyThenOriginalRevocationIsNotAReusableResult() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = IconAuthorityState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let admission = module.module.supervisor.admission
        state.onReply { admission.setEnabled(false) }
        do { _ = try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker); Issue.record("Retired native pixels") } catch {}
        #expect(state.counts == (0, 1, 1) && worker.activeCount == 0)
        state.onReply(nil)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == (0, 1, 1), "Recovery must not retry the decoder")
        _ = try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker)
        #expect(state.counts == (0, 2, 2))
        await registry.shutdown()
    }

    @Test func boundedDefaultReaderPreservesPrivateBytesAndRejectsInvalidSources() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private"), bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        #expect(try AskSmallIconDecoder.read(.file(file)) == bytes)
        #expect(try AskSmallIconDecoder.read(.data(bytes)) == bytes)
        #expect(try AskSmallIconDecoder.read(.data(Data(repeating: 1, count: 262_144))).count == 262_144)
        for input in [AskSmallIconDecoder.Input.data(Data()), .data(Data(count: 262_145)), .file(root), .file(root.appendingPathComponent("missing")), .file(URL(string: "https://private.test/icon")!)] {
            do { _ = try AskSmallIconDecoder.read(input); Issue.record("Invalid source") } catch {}
        }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
