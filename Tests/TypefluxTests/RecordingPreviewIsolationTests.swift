import AppKit
import AVFoundation
import Darwin
import SwiftUI
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

private final class RecordingPreviewClient: ClipboardPlaybackClient, @unchecked Sendable {
    let lock = NSLock()
    var value = MediaPlaybackState(phase: .paused, elapsed: 0, duration: 2)
    var commands: [(MediaPlaybackMessage.Kind, Double?, MediaPlaybackRange?)] = []
    var stopped = false
    var delay: UInt64 = 0
    init() {
        value.video = true; value.frame = .init(width: 64, height: 32, time: 0)
        value.pixels = Data(Array(repeating: [UInt8(20), 90, 250, 255], count: 2048).flatMap { $0 })
    }
    var calls: [MediaPlaybackMessage.Kind] { lock.withLock { commands.map(\.0) } }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) async throws -> MediaPlaybackState {
        try await request(kind, fraction: fraction, range: nil)
    }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?) async throws -> MediaPlaybackState {
        lock.withLock { commands.append((kind, fraction, range)) }
        if delay > 0 { let delay = delay; await Task.detached { try? await Task.sleep(nanoseconds: delay) }.value }
        return lock.withLock {
            switch kind {
            case .playRange: value.elapsed = range!.start; value.phase = .playing
            case .pause: value.phase = .paused
            case .seekPaused: value.elapsed = fraction! * value.duration; value.phase = .paused
            case .volume: value.volume = fraction!
            default: break
            }
            return value
        }
    }
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws {} // No external child in this fixture.
    func stop() { lock.withLock { stopped = true } }
}

@MainActor final class RecordingPreviewIsolationTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Recording preview did not settle")
    }
    private func fixture(_ client: RecordingPreviewClient) -> ScreenRecordingCoordinatorTests.Fixture {
        .init(playback: ClipboardAudioPlayback(video: true, open: { _ in client }))
    }
    private func preview(_ fixture: ScreenRecordingCoordinatorTests.Fixture) async {
        await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
    }
    func testRangeEnvelopeRejectsNonfiniteMissingMixedAndReversedBounds() throws {
        for range in [MediaPlaybackRange(start: .nan, end: 2), .init(start: 0, end: .infinity), .init(start: -1, end: 2),
                      .init(start: 2, end: 1), .init(start: 0, end: 86_401)] {
            XCTAssertThrowsError(try MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .playRange, range: range).validate())
        }
        XCTAssertThrowsError(try MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .playRange).validate())
        XCTAssertThrowsError(try MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .status, range: .init(start: 0, end: 1)).validate())
        XCTAssertThrowsError(try MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .seekPaused, fraction: .nan).validate())
        let valid = MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .playRange, range: .init(start: 0.2, end: 1))
        try valid.validate(); XCTAssertLessThan(try JSONEncoder().encode(valid).count, 2048)
    }
    func testRecordingHasSeparateEightGiBSourceBudgetWithoutCopyingSparseFixture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.mov")
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o600); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, 600 * 1024 * 1024), 0)
        XCTAssertThrowsError(try ClipboardPlaybackSource(url))
        let source = try ClipboardPlaybackSource(url, limit: 8 * 1024 * 1024 * 1024); try source.check()
        XCTAssertEqual(ftruncate(fd, 8 * 1024 * 1024 * 1024 + 1), 0)
        XCTAssertThrowsError(try source.check())
        XCTAssertThrowsError(try ClipboardPlaybackSource(url, limit: 8 * 1024 * 1024 * 1024))
    }
    func testExplicitTrimPlaybackAndLatestScrubDoNotQueuePlayCommands() async throws {
        let client = RecordingPreviewClient(), fixture = fixture(client)
        await preview(fixture)
        XCTAssertEqual(fixture.model.state, .preview); XCTAssertTrue(fixture.model.canExport)
        XCTAssertFalse(client.calls.contains(.playRange))
        fixture.model.trimStart = 0.3; fixture.model.trimEnd = 1.2
        fixture.model.togglePlayback(); fixture.model.togglePlayback()
        try await wait { fixture.model.isPlaying && !fixture.model.playback.isBusy }
        XCTAssertEqual(client.calls.filter { $0 == .playRange }.count, 1)
        fixture.model.seek(0.4); fixture.model.seek(0.6); fixture.model.seek(0.8)
        try await wait { fixture.model.currentTime == 0.8 && !fixture.model.playback.isBusy }
        XCTAssertFalse(fixture.model.isPlaying)
        XCTAssertEqual(client.calls.filter { $0 == .seekPaused }.count, 1)
        fixture.model.seek(.nan)
        fixture.model.playback.play(range: .init(start: 2, end: 1))
        XCTAssertFalse(fixture.model.playback.isBusy)
        await fixture.clean()
    }
    func testFailedPreviewRetainsOriginalAndDoesNotRepeatCaptureOrLoad() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture(playback: ClipboardAudioPlayback(video: true, open: { _ in throw MediaFailure.unavailable }))
        await preview(fixture)
        let source = try XCTUnwrap(fixture.model.sourceURL)
        XCTAssertEqual(fixture.model.state, .preview); XCTAssertNotNil(fixture.model.error)
        XCTAssertFalse(fixture.model.canExport); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(fixture.engine.starts, 1); XCTAssertEqual(fixture.engine.stops, 1)
        fixture.model.togglePlayback(); fixture.model.export()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        fixture.model.reloadPreviewPlayback(); await fixture.model.pendingTask?.value
        XCTAssertNotNil(fixture.model.error); XCTAssertEqual(fixture.engine.starts, 1)
        fixture.model.retirePreview(); fixture.model.reloadPreviewPlayback(); fixture.model.revealOriginal() // Denied, no Finder launch.
        await fixture.clean()
    }
    func testHideAndAccountRetirementClearPixelsAndBlockExportButKeepSource() async throws {
        _ = NSApplication.shared
        for action in 0..<3 {
            let client = RecordingPreviewClient(), fixture = fixture(client)
            await preview(fixture)
            let source = try XCTUnwrap(fixture.model.sourceURL)
            let panel = ScreenRecordingPreviewPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.retire = { fixture.model.retirePreview() }
            if action == 0 { panel.orderOut(nil) }
            else if action == 1 { panel.close() }
            else { NotificationCenter.default.post(name: .authDidLogout, object: nil) }
            XCTAssertNil(fixture.model.playback.image); XCTAssertFalse(fixture.model.canExport)
            XCTAssertTrue(client.stopped); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            fixture.model.togglePlayback(); fixture.model.seek(1); fixture.model.setTrimStart(1); fixture.model.resetTrim()
            XCTAssertFalse(client.calls.contains(.playRange))
            await fixture.clean()
        }
    }
    func testRetirementDuringUncooperativeLoadRejectsLateFrameAndRetainsRecording() async throws {
        let client = RecordingPreviewClient(); client.delay = 250_000_000
        let fixture = fixture(client)
        await fixture.recording(); fixture.model.stop()
        try await wait { !client.calls.isEmpty }
        fixture.model.retirePreview(); await fixture.model.pendingTask?.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(fixture.model.playback.image); XCTAssertFalse(fixture.model.playback.isLoaded)
        XCTAssertNotNil(fixture.model.sourceURL); XCTAssertEqual(fixture.engine.starts, 1)
        await fixture.clean()
    }
    func testExportFailureKeepsTrimAndExplicitReloadDoesNotReplayExport() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture(exportFails: true,
            playback: ClipboardAudioPlayback(video: true, open: { _ in RecordingPreviewClient() }))
        await preview(fixture)
        fixture.model.trimStart = 0.2; fixture.model.trimEnd = 0.9
        fixture.model.export(); await fixture.model.pendingTask?.value
        XCTAssertEqual(fixture.model.state, .preview); XCTAssertNotNil(fixture.model.sourceURL)
        XCTAssertFalse(fixture.model.playback.isLoaded)
        fixture.model.reloadPreviewPlayback(); await fixture.model.pendingTask?.value
        XCTAssertTrue(fixture.model.playback.isLoaded); XCTAssertFalse(fixture.model.isPlaying)
        XCTAssertEqual(fixture.model.trimStart, 0.2); XCTAssertEqual(fixture.model.trimEnd, 0.9)
        await fixture.clean()
    }
    func testRealRecordingHelperStopsAtTrimEndAndPausedSeekNeverResumes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silent.mov")
        try await ClipboardVideoPlaybackTests.movie(url) // Verified fixture has no audio track.
        let audioTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let pool = ClipboardPlaybackPool()
        let client = try await ClipboardPlaybackProcess.open(url, video: true, recording: true, pool: pool, run: { request, _ in
            var request = request; request.timeout = 10
            return try ManagedProcess().runBlocking(request, isCancelled: { false })
        })
        let loaded = try await client.request(.load); XCTAssertTrue(loaded.video)
        _ = try await client.request(.volume, fraction: 0)
        let playing = try await client.request(.playRange, fraction: nil, range: .init(start: 0.2, end: 0.6))
        XCTAssertEqual(playing.phase, .playing)
        try await Task.sleep(for: .milliseconds(750))
        let stopped = try await client.request(.status)
        XCTAssertEqual(stopped.phase, .paused); XCTAssertEqual(stopped.elapsed, 0.6, accuracy: 0.03)
        let seek = try await client.request(.seekPaused, fraction: 0.4)
        XCTAssertEqual(seek.phase, .paused); XCTAssertEqual(seek.elapsed, loaded.duration * 0.4, accuracy: 0.01)
        _ = try await client.request(.playRange, fraction: nil, range: .init(start: 0.2, end: 0.6))
        _ = try await client.request(.pause)
        client.stop(); await pool.shutdown(); XCTAssertEqual(pool.activeCount, 0)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/recording-preview-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("silent.mov"); try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
    }
    func testActualEditorRawPixelsAndNativeHideClearWithoutDeletingSource() async throws {
        _ = NSApplication.shared
        let client = RecordingPreviewClient(), fixture = fixture(client)
        await preview(fixture)
        let host = NSHostingView(rootView: ScreenRecordingPreviewView(model: fixture.model).frame(width: 920, height: 632))
        let panel = ScreenRecordingPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 632), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .aqua)
        panel.retire = { fixture.model.retirePreview() }; panel.contentView = host; panel.orderFront(nil)
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        var blue = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 10) { for x in stride(from: 0, to: rep.pixelsWide, by: 10) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.blueComponent - c.redComponent > 0.3 { blue += 1 }
        } }
        XCTAssertGreaterThan(blue, 100)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/recording-preview-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("recording-preview.png"))
        panel.orderOut(nil); XCTAssertNil(fixture.model.playback.image); XCTAssertNotNil(fixture.model.sourceURL)
        panel.contentView = nil; await fixture.clean()
    }
    func testPresenterOwnerReleaseAndActualPanelHideRetirePlayback() async throws {
        _ = NSApplication.shared
        for ownerRelease in [false, true] {
            let client = RecordingPreviewClient(), fixture = fixture(client)
            await preview(fixture)
            var presenter: ScreenRecordingWindowController? = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
            presenter?.show(fixture.model)
            XCTAssertTrue(presenter?.window is ScreenRecordingPreviewPanel)
            let window = presenter?.window
            weak var weakPresenter = presenter
            if ownerRelease { presenter = nil; try await wait { fixture.model.playback.image == nil }; XCTAssertNil(weakPresenter) }
            else { presenter?.window?.orderOut(nil); XCTAssertNil(fixture.model.playback.image); presenter?.hide(); await presenter?.deviceTask?.value }
            XCTAssertTrue(client.stopped); XCTAssertNotNil(fixture.model.sourceURL)
            window?.orderOut(nil); window?.contentView = nil
            await fixture.clean()
        }
    }
}
