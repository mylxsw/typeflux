import AppKit
import AVFoundation
import Darwin
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class TimelineGate: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run() throws -> ManagedProcess.Result { lock.withLock { calls += 1 }; gate.wait(); throw MediaFailure.unavailable }
}
private actor TimelinePending {
    var continuation: CheckedContinuation<ScreenRecordingPreviewMedia, Error>?
    var started: Bool { continuation != nil }
    func load() async throws -> ScreenRecordingPreviewMedia {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resolve() { continuation?.resume(returning: .init(waveform: [0.7], fps: 99, audio: .available)); continuation = nil }
}

@MainActor final class RecordingTimelineIsolationTests: XCTestCase {
    private func folder() throws -> URL { try AskAttachmentFixture.directory() }
    private func worker() throws -> MediaWorker {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/timeline-validation")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MediaWorker(timeout: 30, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = root.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timeline work did not settle")
    }
    private func metadata() -> MediaRecordingTimeline {
        .init(duration: 2, width: 160, height: 120, fps: 30,
              rasters: Array(repeating: .init(width: 160, height: 120), count: 10), audio: .absent)
    }
    func testStrictEnvelopeMetadataRasterAndAudioContracts() throws {
        let request = MediaRequest(operation: .recordingTimeline)
        var response = MediaResponse(id: request.id); response.timeline = metadata()
        try response.validate(for: request)
        let mutations: [(inout MediaResponse) -> Void] = [
            { $0.timeline = nil }, { $0.id = UUID() }, { $0.version = 2 }, { $0.failure = .unavailable },
            { $0.items = [.init(text: "x")] }, { $0.clipboard = .init(duration: 2) },
            { $0.timeline?.duration = .infinity }, { $0.timeline?.duration = 86_401 },
            { $0.timeline?.width = .nan }, { $0.timeline?.height = 9000 }, { $0.timeline?.fps = 241 },
            { $0.timeline?.rasters.removeLast() }, { $0.timeline?.rasters[0].stride = Int.max },
            { $0.timeline?.rasters[0].page = 1 }, { $0.timeline?.waveform = [0] },
            { $0.timeline?.audio = .available }, { $0.timeline?.width = 8192; $0.timeline?.height = 8192 }
        ]
        for mutate in mutations { var bad = response; mutate(&bad); XCTAssertThrowsError(try bad.validate(for: request)) }
        var value = metadata(); value.audio = .available; value.waveform = Array(repeating: 0.5, count: 160); try value.validate()
        value.waveform[0] = .nan; XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try response.validate(for: .init(id: request.id, operation: .image)))
        var invalid = request; invalid.preview = .init(width: 200, height: 120); XCTAssertThrowsError(try invalid.validate())
        XCTAssertLessThan(try JSONEncoder().encode(response).count, 16 * 1024)
    }
    func testWholeDurationAllTrackPeakMergeAndPCMBudgets() throws {
        var peaks = MediaRecordingPeaks(duration: 1200)
        try peaks.admit(bytes: 4)
        try peaks.append([0.2, .nan, .infinity], time: 900)
        try peaks.append([-0.8], time: 900) // Another track, same timeline bucket.
        try peaks.append([2], time: 1200)
        XCTAssertEqual(peaks.peaks[120], 0.8); XCTAssertEqual(peaks.peaks[159], 1)
        XCTAssertEqual(peaks.peaks[0], 0); XCTAssertEqual(peaks.peaks.count, 160)
        for bytes in [-1, 0, 1, Int.max, 4 * 1024 * 1024 + 4] { XCTAssertThrowsError(try peaks.admit(bytes: bytes)) }
        var full = MediaRecordingPeaks(duration: 1)
        for _ in 0..<128 { try full.admit(bytes: 4 * 1024 * 1024) }
        XCTAssertThrowsError(try full.admit(bytes: 4))
        for time in [Double.nan, .infinity, -1, 1201] { XCTAssertThrowsError(try peaks.append([1], time: time)) }
        var invalid = MediaRecordingPeaks(duration: .nan); XCTAssertThrowsError(try invalid.append([1], time: 0))
    }
    func testRealHelperBatchPreservesRotationOrderAndPixelLeaseAfterModelRelease() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.mov"); try await ClipboardVideoPlaybackTests.movie(url)
        let worker = try worker(), budget = AskToolPixelBudget(limit: MediaRecordingTimeline.pixelBytes * 2)
        let loader = ScreenRecordingTimelineLoader(worker: worker, budget: budget)
        var media: ScreenRecordingPreviewMedia? = try await loader.load(url)
        XCTAssertEqual(media?.thumbnails.count, 10); XCTAssertEqual(media?.size, CGSize(width: 32, height: 64))
        XCTAssertEqual(media?.audio, .absent); XCTAssertTrue(media?.waveform.isEmpty == true)
        let first = try XCTUnwrap(media?.thumbnails.first), last = try XCTUnwrap(media?.thumbnails.last)
        XCTAssertNotEqual(first.dataProvider?.data as Data?, last.dataProvider?.data as Data?)
        XCTAssertEqual(first.width, 32); XCTAssertEqual(first.height, 64)
        var retained: CGImage? = media?.thumbnails[1]; media = nil
        XCTAssertThrowsError(try budget.acquire(bytes: 1)) // CGImage owns its reservation, independently of model.
        retained = nil; withExtendedLifetime(retained) {}
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
        let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/timeline-validation/silent.mov")
        try? FileManager.default.removeItem(at: evidence); try FileManager.default.copyItem(at: url, to: evidence)
    }
    func testRealHelperAllAudioTracksAndMalformedInputKeepOriginal() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.mov")
        try await ScreenRecordingMediaTests.makeMovie(at: url, withAudio: true)
        let worker = try worker(), loader = ScreenRecordingTimelineLoader(worker: worker)
        let value = try await loader.load(url)
        XCTAssertEqual(value.audio, .available); XCTAssertEqual(value.waveform.count, 160)
        XCTAssertGreaterThan(value.waveform.max() ?? 0, 0.1); XCTAssertGreaterThan(value.fileBytes, 0)
        XCTAssertEqual(value.thumbnails.count, 10)
        try Data("broken movie".utf8).write(to: url)
        do { _ = try await loader.load(url); XCTFail("Malformed recording accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("broken movie".utf8))
        await worker.shutdown()
    }
    func testSourceMutationAndInvalidRawFilesFailClosed() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.mov"); try Data([1]).write(to: url)
        let value = metadata()
        let worker = MediaWorker(run: { request, _ in
            let req = try JSONDecoder().decode(MediaRequest.self, from: request.stdin!)
            let fd = request.directoryDescriptor
            for i in 0..<10 {
                let output = openat(fd, MediaRaster.filename(i), O_CREAT | O_WRONLY, 0o600)
                let bytes = [UInt8](repeating: 0, count: 160 * 120 * 4); _ = write(output, bytes, bytes.count); close(output)
            }
            try Data([2, 3]).write(to: url)
            var response = MediaResponse(id: req.id); response.timeline = value
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        do { _ = try await ScreenRecordingTimelineLoader(worker: worker).load(url); XCTFail("Mutated source accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data([2, 3]))
        let bad = MediaWorker(run: { request, _ in
            let req = try JSONDecoder().decode(MediaRequest.self, from: request.stdin!)
            var response = MediaResponse(id: req.id); response.timeline = value
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        do { _ = try await ScreenRecordingTimelineLoader(worker: bad).load(url); XCTFail("Missing raster accepted") } catch {}
    }
    func testCancelledWorkRetainsAdmissionUntilHostReturnsAndShutdownRefusesNewWork() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.mov"); try Data([1]).write(to: url)
        let gate = TimelineGate(), worker = MediaWorker(run: { _, _ in try gate.run() })
        let loader = ScreenRecordingTimelineLoader(worker: worker)
        let a = Task { try await loader.load(url) }, b = Task { try await loader.load(url) }
        try await wait { gate.count == 2 }; a.cancel(); b.cancel()
        do { _ = try await loader.load(url); XCTFail("Cancelled work freed admission early") } catch {}
        XCTAssertEqual(worker.activeCount, 2)
        worker.preventNewWork(); gate.gate.signal(); gate.gate.signal()
        _ = await a.result; _ = await b.result
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
        do { _ = try await loader.load(url); XCTFail("Shutdown accepted work") } catch {}
    }
    func testOversizedNonlocalSymlinkMissingAndPixelBudgetRefuseBeforeSpawn() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("huge.mov")
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o600); XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(MediaRecordingTimeline.inputBytes + 1)), 0); close(fd)
        let link = directory.appendingPathComponent("link.mov"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let worker = MediaWorker(run: { _, _ in XCTFail("Invalid source dispatched"); throw MediaFailure.unavailable })
        let loader = ScreenRecordingTimelineLoader(worker: worker)
        for input in [url, link, directory, directory.appendingPathComponent("missing"), URL(string: "https://example.invalid/movie")!] {
            do { _ = try await loader.load(input); XCTFail("Invalid source accepted") } catch {}
        }
        let emptyBudget = ScreenRecordingTimelineLoader(worker: worker, budget: AskToolPixelBudget(limit: 1))
        do { _ = try await emptyBudget.load(url); XCTFail("Budget ignored") } catch {}
    }
    func testLeaseKeepsPixelsUntilHostAndChildBothRetire() throws {
        let budget = AskToolPixelBudget(limit: 1), lease = MediaLease()
        lease.retained = try budget.acquire(bytes: 1); lease.started(); lease.reaped()
        XCTAssertThrowsError(try budget.acquire(bytes: 1))
        lease.returned(); XCTAssertNoThrow(try budget.acquire(bytes: 1))
    }
    func testHiddenAccountAndCancelledCoordinatorRejectLateTimelineWithoutDeletingSource() async throws {
        for action in 0..<3 {
            let pending = TimelinePending(), fixture = ScreenRecordingCoordinatorTests.Fixture()
            fixture.model.loadTimeline = { _ in try await pending.load() }
            await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
            try await wait { await pending.started }
            let original = try XCTUnwrap(fixture.model.sourceURL)
            if action == 0 {
                let panel = ScreenRecordingPreviewPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.retire = { fixture.model.retirePreview() }; panel.orderOut(nil)
            }
            else if action == 1 { NotificationCenter.default.post(name: .authDidLogout, object: nil) }
            else { fixture.model.retirePreview() }
            await pending.resolve(); try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(fixture.model.media.thumbnails.isEmpty); XCTAssertEqual(fixture.model.media.fps, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            await fixture.clean()
        }
    }
    func testTimelineFailureIsNotSilenceAndEditorRetainsExportAndSource() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        fixture.model.loadTimeline = { _ in throw MediaFailure.unavailable }
        await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
        try await wait { fixture.model.media.audio == .unavailable }
        XCTAssertTrue(fixture.model.canExport); XCTAssertNotNil(fixture.model.sourceURL)
        XCTAssertEqual(fixture.model.media.audioNoticeKey, "recording.timelineUnavailable")
        XCTAssertEqual(ScreenRecordingPreviewMedia().audioNoticeKey, "recording.timelineLoading")
        XCTAssertEqual(ScreenRecordingPreviewMedia(audio: .absent).audioNoticeKey, "recording.noAudioTrack")
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ScreenRecordingTimelineView(model: fixture.model).frame(width: 700, height: 110).padding().background(Color.white))
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 732, height: 142), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .aqua); panel.contentView = host; panel.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/timeline-validation")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("timeline.png"))
        panel.orderOut(nil); panel.contentView = nil; await fixture.clean()
    }
}
