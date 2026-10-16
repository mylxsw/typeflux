import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class TimelineAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, reads = 0
    var counts: [Int] { lock.withLock { [runs, reads] } }
    func run() { lock.withLock { runs += 1 } }
    func read() { lock.withLock { reads += 1 } }
}
private final class TimelineSourceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, entered = false
    var waiting: Bool { condition.withLock { entered && held } }
    func wait() {
        condition.lock(); defer { condition.unlock() }; entered = true
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Recording timeline original batch authority", .serialized)
struct RecordingTimelineAuthorityTests {
    private func file(_ root: URL, name: String = "fixture.mov") throws -> URL {
        let url = root.appendingPathComponent(name); try Data([1, 2, 3]).write(to: url); return url
    }
    private func worker(_ state: TimelineAuthorityState) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            let raster = MediaRaster(width: 2, height: 2)
            let count = request.operation == .recordingTimeline ? 10 : 1
            let bytes = Data(repeating: 0, count: 16)
            for index in 0..<count {
                let fd = openat(p.directoryDescriptor, MediaRaster.filename(index), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                guard fd >= 0 else { throw MediaFailure.unavailable }
                let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; close(fd)
                guard written == 16 else { throw MediaFailure.unavailable }
            }
            var response = MediaResponse(id: request.id)
            if request.operation == .recordingTimeline {
                response.timeline = .init(duration: 1, width: 2, height: 2, fps: 30,
                    rasters: Array(repeating: raster, count: count), audio: .absent)
            } else { response.preview = .init(rasters: [raster]) }
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func preReadyAndWrongOwnerGrantsCannotBecomeCurrent() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TimelineAuthorityState(), worker = self.worker(state), original = worker.authorization()
        #expect(!worker.permits(original))
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline)
        let boundPreReady = worker.authorization()
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
        #expect(!worker.permits(original) && !worker.permits(boundPreReady))
        #expect(throws: MediaFailure.self) {
            try worker.perform(.recordingTimeline, input: .data(Data([1])), authorization: original,
                               isCancelled: { false }) { response, _ in response }
        }
        let current = worker.authorization()
        #expect(worker.permits(current))
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(!foreign.permits(current))
        #expect(throws: MediaFailure.self) {
            try foreign.perform(.image, input: .data(Data([1])), authorization: current,
                                isCancelled: { false }) { response, _ in response }
        }
        #expect(state.counts == [0, 0] && worker.activeCount == 0)
        let count = try worker.perform(.recordingTimeline, input: .data(Data([1])), authorization: current,
            isCancelled: { !worker.permits(current) }) { response, _ in response.timeline?.rasters.count }
        #expect(count == 10 && state.counts[0] == 1 && worker.activeCount == 0)
        await registry.shutdown()
        #expect(!worker.permits(current))
    }

    @Test(arguments: ["timeline", "video", "gif"])
    func recoveredLaneCannotAdoptBatchHeldInSourceInspection(_ kind: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root, name: kind == "gif" ? "fixture.gif" : "fixture.mov")
        let state = TimelineAuthorityState(), worker = self.worker(state), gate = TimelineSourceGate()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
        let budget = AskToolPixelBudget(limit: MediaRecordingTimeline.pixelBytes * 2)
        let loader = ScreenRecordingTimelineLoader(worker: worker, budget: budget, readSource: { url, limit in
            state.read(); let source = try ClipboardPlaybackSource(url, limit: limit); gate.wait(); return source
        })
        let pending = Task {
            if kind == "timeline" { _ = try await loader.load(url) }
            else { _ = try await loader.thumbnail(url) }
        }
        await wait { gate.waiting }
        let original = worker.authorization()
        await registry.disable(.recordingTimeline); try await registry.start(.recordingTimeline)
        #expect(!worker.permits(original) && worker.permits(worker.authorization()))
        #expect(state.counts == [0, 1] && worker.activeCount == 0)
        gate.release()
        do { try await pending.value; Issue.record("Old batch adopted recovered lane") } catch {}
        #expect(state.counts == [0, 1])
        // A fresh explicit batch can use the same live loader after recovery.
        if kind == "timeline" {
            let media = try await loader.load(url); #expect(media.thumbnails.count == 10 && media.fileBytes == 3)
        } else {
            let image = try await loader.thumbnail(url); #expect(image.width == 2 && image.height == 2)
        }
        #expect(state.counts == [1, 2])
        await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func cancelledSourcePreparationKeepsPixelsUntilActualReturn(_ poster: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = TimelineAuthorityState(), worker = self.worker(state), gate = TimelineSourceGate()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
        let size = poster ? 200 * 120 * 8 : MediaRecordingTimeline.pixelBytes * 2
        let budget = AskToolPixelBudget(limit: size)
        let loader = ScreenRecordingTimelineLoader(worker: worker, budget: budget, readSource: { url, limit in
            state.read(); let source = try ClipboardPlaybackSource(url, limit: limit); gate.wait(); return source
        })
        let pending = Task {
            if poster { _ = try await loader.thumbnail(url) } else { _ = try await loader.load(url) }
        }
        await wait { gate.waiting }; pending.cancel()
        #expect(throws: (any Error).self) { try budget.acquire(bytes: 1) }
        #expect(state.counts == [0, 1])
        gate.release(); _ = await pending.result
        #expect(state.counts == [0, 1] && worker.activeCount == 0)
        _ = try budget.acquire(bytes: size)
        await registry.shutdown()
    }

    @Test func metadataOnlyRemainsIndependentAndCancelledInspectionKeepsSlotsUntilReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), gate = TimelineSourceGate(), state = TimelineAuthorityState()
        let worker = self.worker(state), loader = ScreenRecordingTimelineLoader(worker: worker, readSource: { url, limit in
            state.read(); return try ClipboardPlaybackSource(url, limit: limit)
        })
        do { _ = try await loader.load(url); Issue.record("Unbound lane entered source") } catch {}
        do { _ = try await loader.thumbnail(url); Issue.record("Unbound lane entered poster source") } catch {}
        #expect(state.counts == [0, 0])
        #expect(try await ScreenRecordingTimelineLoader.inspect(url).bytes == 3)
        let read: ScreenRecordingTimelineLoader.SourceReader = { url, limit in
            state.read(); let source = try ClipboardPlaybackSource(url, limit: limit); gate.wait(); return source
        }
        let a = Task { try await ScreenRecordingTimelineLoader.inspect(url, readSource: read) }
        let b = Task { try await ScreenRecordingTimelineLoader.inspect(url, readSource: read) }
        await wait { state.counts[1] == 2 }; a.cancel(); b.cancel()
        do { _ = try await ScreenRecordingTimelineLoader.inspect(url); Issue.record("Freed occupied metadata slot") } catch {}
        gate.release(); _ = await a.result; _ = await b.result
        #expect(try await ScreenRecordingTimelineLoader.inspect(url).bytes == 3)
        #expect(state.counts[0] == 0)
    }

    @Test func standaloneAuthorizationDoesNotCrossBindingOrShutdown() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")), original = worker.authorization()
        #expect(worker.permits(original))
        let value = try worker.owned(id: UUID(), retaining: nil, authorization: original,
                                     isCancelled: { false }) { _, _, _, _, _ in 7 }
        #expect(value == 7)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
        #expect(!worker.permits(original) && worker.permits(worker.authorization()))
        let current = worker.authorization(); worker.preventNewWork()
        #expect(!worker.permits(current))
        await registry.shutdown()
    }
}
