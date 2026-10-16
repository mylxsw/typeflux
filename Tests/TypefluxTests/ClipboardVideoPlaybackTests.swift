import AppKit
import AVFoundation
import Darwin
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class SyntheticVideoClient: ClipboardPlaybackClient, @unchecked Sendable {
    let lock = NSLock()
    private var recorded: [MediaPlaybackMessage.Kind] = []
    var calls: [MediaPlaybackMessage.Kind] { lock.withLock { recorded } }
    var state = MediaPlaybackState(phase: .paused, elapsed: 0, duration: 2)
    private var isStopped = false
    var stopped: Bool { lock.withLock { isStopped } }
    var delay: UInt64 = 0
    init() {
        state.video = true; state.frame = .init(width: 64, height: 32, time: 0)
        state.pixels = Data(Array(repeating: [UInt8(0), 100, 255, 255], count: 64 * 32).flatMap { $0 })
    }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) async throws -> MediaPlaybackState {
        lock.withLock { recorded.append(kind) }
        if delay > 0 { let delay = delay; await Task.detached { try? await Task.sleep(nanoseconds: delay) }.value }
        return lock.withLock {
            if kind == .volume { state.volume = fraction! }
            if kind == .seek { state.elapsed = fraction! * 2 }
            if kind == .play { state.phase = .playing }
            if kind == .pause { state.phase = .paused }
            return state
        }
    }
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws {} // No child in this injected client.
    func stop() { lock.withLock { isStopped = true } }
}

@MainActor final class ClipboardVideoPlaybackTests: XCTestCase {
    private func wait(_ check: () -> Bool) async throws {
        for _ in 0..<600 { if check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Video condition did not finish")
    }
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private var url: URL { URL(fileURLWithPath: "/private/synthetic.mov") }
    private func sockets() throws -> (MediaPlaybackSocket, MediaPlaybackSocket) {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        return (try MediaPlaybackSocket(owning: pair[0]), try MediaPlaybackSocket(owning: pair[1]))
    }
    func testFrameAndVolumeContractRejectsOverflowMixedTypeAndNonfiniteValues() throws {
        let valid = MediaPlaybackFrame(width: 1280, height: 720, time: 1)
        try valid.validate(duration: 2)
        for frame in [MediaPlaybackFrame(width: Int.max, height: Int.max, time: 0), .init(width: 1280, height: 1280, time: 0),
                      .init(width: -1, height: 1, time: 0), .init(width: 1, height: 1, time: .nan), .init(width: 1, height: 1, time: 3)] {
            XCTAssertThrowsError(try frame.validate(duration: 2))
        }
        var broken = valid; broken.stride += 1; XCTAssertThrowsError(try broken.validate(duration: 2))
        broken = valid; broken.bytes -= 1; XCTAssertThrowsError(try broken.validate(duration: 2))
        var state = MediaPlaybackState(phase: .paused, elapsed: 0, duration: 2)
        state.frame = valid; XCTAssertThrowsError(try state.validate()); state.video = true; try state.validate()
        state.volume = .nan; XCTAssertThrowsError(try state.validate()); state.volume = 1
        state.pixels = Data([1, 2, 3])
        let encoded = try JSONEncoder().encode(state)
        XCTAssertNil(try JSONDecoder().decode(MediaPlaybackState.self, from: encoded).pixels)
        XCTAssertLessThan(encoded.count, MediaPlaybackMessage.maximumBytes)
        for fraction in [Double.nan, .infinity, -1, 2] {
            XCTAssertThrowsError(try MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .volume, fraction: fraction).validate())
        }
        try MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .loadVideo).validate()
        try MediaPlaybackMessage(id: UUID(), sequence: 1, kind: .volume, fraction: 0).validate()
    }
    func testPixelChannelIsBoundedAndBackpressuresWithoutExpandingControlFrames() async throws {
        let (host, child) = try sockets(); defer { host.stop(); child.stop() }
        XCTAssertThrowsError(try host.receivePixels(count: Int.max, deadline: .now))
        XCTAssertThrowsError(try host.receivePixels(count: 0, deadline: .now))
        XCTAssertThrowsError(try child.sendPixels(Data(), deadline: .now))
        XCTAssertThrowsError(try child.sendPixels(Data(count: MediaPlaybackFrame.maximumBytes + 1), deadline: .now))
        let pixels = Data(repeating: 77, count: 1024 * 1024)
        let send = Task.detached { try child.sendPixels(pixels, deadline: .now.advanced(by: .seconds(2))) }
        let received = try await Task.detached { try host.receivePixels(count: pixels.count, deadline: .now.advanced(by: .seconds(2))) }.value
        try await send.value; XCTAssertEqual(received, pixels)
        let blocked = Task.detached { try child.sendPixels(Data(count: MediaPlaybackFrame.maximumBytes), deadline: .now.advanced(by: .milliseconds(30))) }
        do { try await blocked.value; XCTFail("Unconsumed frame must time out") } catch {}
        XCTAssertEqual(MediaPlaybackSocket.maximumFrameBytes, 2048)
    }
    func testVideoControlsAreExplicitAndScopeRetiresPixelsAndReservation() async throws {
        let scope = AskImagePresentationScope(), client = SyntheticVideoClient()
        let budget = AskToolPixelBudget(limit: MediaPlaybackFrame.maximumBytes * 2 + 64 * 32 * 8)
        let model = ClipboardAudioPlayback(video: true, budget: budget, open: { _ in client })
        model.setVolume(.nan); model.setVolume(0); XCTAssertTrue(client.calls.isEmpty)
        model.load(url, access: access(scope)); try await wait { model.image != nil }
        XCTAssertFalse(model.isPlaying); XCTAssertThrowsError(try budget.acquire(bytes: 64 * 32 * 4 + 1))
        model.setVolume(0.25); model.setVolume(0.75)
        try await wait { !model.isBusy && model.volume == 0.25 }
        XCTAssertEqual(client.calls.filter { $0 == .volume }.count, 1)
        model.toggle(); try await wait { model.isPlaying && !model.isBusy }
        model.seek(to: 0.5); try await wait { model.elapsed == 1 && !model.isBusy }
        var retained = model.image
        scope.invalidate(); XCTAssertNil(model.image); XCTAssertFalse(model.isLoaded); XCTAssertTrue(client.stopped)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertThrowsError(try budget.acquire(bytes: MediaPlaybackFrame.maximumBytes * 2 + 64 * 32 * 8)); withExtendedLifetime(retained) {}; retained = nil
        _ = try budget.acquire(bytes: MediaPlaybackFrame.maximumBytes * 2 + 64 * 32 * 8)
    }
    func testOldSliderGestureCannotControlReplacementWithFreshPermission() async throws {
        let scope = AskImagePresentationScope(), first = SyntheticVideoClient(), second = SyntheticVideoClient()
        let originalURL = url
        let model = ClipboardAudioPlayback(video: true, open: { input in input == originalURL ? first : second })
        defer { model.stop() }
        model.load(originalURL, access: access(scope)); try await wait { model.isLoaded }
        let oldInteraction = model.interactionID
        scope.invalidate()
        model.load(URL(fileURLWithPath: "/private/replacement.mov"), access: access(scope))
        try await wait { model.isLoaded }
        model.seek(to: 0.8, interactionID: oldInteraction)
        model.setVolume(0.2, interactionID: oldInteraction)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(second.calls.contains(.seek)); XCTAssertFalse(second.calls.contains(.volume))
        let current = model.interactionID
        model.seek(to: 0.5, interactionID: current)
        try await wait { model.elapsed == 1 && !model.isBusy }
        model.setVolume(0.3, interactionID: current)
        try await wait { model.volume == 0.3 && !model.isBusy }
        XCTAssertEqual(second.calls.filter { $0 == .seek }.count, 1)
        XCTAssertEqual(second.calls.filter { $0 == .volume }.count, 1)
        XCTAssertFalse(second.calls.contains(.play)); XCTAssertTrue(first.stopped)
    }
    func testPixelBudgetDeniesBeforeFactoryAndCancelledUncooperativeReplyKeepsLease() async throws {
        let scope = AskImagePresentationScope(), client = SyntheticVideoClient(); client.delay = 150_000_000
        let budget = AskToolPixelBudget(limit: MediaPlaybackFrame.maximumBytes * 2)
        let first = ClipboardAudioPlayback(video: true, budget: budget, open: { _ in client })
        first.load(url, access: access(scope)); try await wait { !client.calls.isEmpty }
        first.stop(); XCTAssertNil(first.image); XCTAssertThrowsError(try budget.acquire(bytes: 1))
        let second = ClipboardAudioPlayback(video: true, budget: budget, open: { _ in XCTFail("Budget checked too late"); return client })
        second.load(url, access: access(scope)); try await wait { second.failed }
        try await Task.sleep(for: .milliseconds(200)); XCTAssertNil(first.image)
        _ = try budget.acquire(bytes: MediaPlaybackFrame.maximumBytes * 2); second.stop()
    }
    func testFrameReservationRemainsUntilHostAndChildBothRetire() throws {
        let pool = ClipboardPlaybackPool(), budget = AskToolPixelBudget(limit: 64)
        let (id, lease) = try pool.reserve()
        try pool.retainPixels(id, reservation: budget.acquire(bytes: 64))
        XCTAssertThrowsError(try pool.retainPixels(id, reservation: AskToolPixelBudget(limit: 1).acquire(bytes: 1)))
        lease.started(); lease.returned()
        XCTAssertThrowsError(try budget.acquire(bytes: 1))
        lease.reaped()
        // Deferred disk cleanup also retains the reservation until its callback finishes.
        let deadline = Date().addingTimeInterval(2)
        while pool.activeCount != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(pool.activeCount, 0); _ = try budget.acquire(bytes: 64)
        XCTAssertThrowsError(try pool.retainPixels(id, reservation: budget.acquire(bytes: 1)))
    }
    func testMissingPixelsWrongModeAndFailureDoNotRetryOrRevealFrames() async throws {
        for mode in 0..<3 {
            let scope = AskImagePresentationScope(), client = SyntheticVideoClient()
            if mode == 0 { client.state.pixels = Data([0]) }
            if mode == 1 { client.state.video = false; client.state.frame = nil; client.state.pixels = nil }
            if mode == 2 { client.state.frame = nil }
            let model = ClipboardAudioPlayback(video: true, open: { _ in client })
            model.load(url, access: access(scope)); try await wait { model.failed }
            model.load(url, access: access(scope)); model.toggle()
            XCTAssertEqual(client.calls, [.load]); XCTAssertNil(model.image); XCTAssertTrue(client.stopped); model.stop()
        }
    }
    func testActualPanelHideSelectionDeletionAndAccountClearVideo() async throws {
        _ = NSApplication.shared
        let panel = ClipboardPanelModel(), entry = ClipboardTestSupport.entry(.video, filePaths: [url.path])
        let other = ClipboardTestSupport.entry(.video, filePaths: ["/private/other.mov"])
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "video-" + UUID().uuidString)!)
        let controller = ClipboardPanelController(settingsStore: settings, thumbnailDecoder: { _, _ in throw MediaFailure.unavailable })
        defer { controller.dismiss() }
        for change in 0..<4 {
            panel.reset(entries: [entry, other]); controller.present(panel)
            let client = SyntheticVideoClient(), model = ClipboardAudioPlayback(video: true, open: { _ in client })
            model.load(url, access: controller.thumbnails.access(for: entry)); try await wait { model.image != nil }
            switch change {
            case 0: controller.presentedWindow?.orderOut(nil)
            case 1: panel.selectedIndex = panel.selectedIndex == 0 ? 1 : 0
            case 2: panel.replaceEntries([])
            default: NotificationCenter.default.post(name: .authDidLogout, object: nil)
            }
            XCTAssertNil(model.image); XCTAssertTrue(client.stopped)
        }
    }
    func testOwnerReleaseStopsVideoAndOldAccessCannotBlessReplacement() async throws {
        let scope = AskImagePresentationScope(), client = SyntheticVideoClient(), original = access(scope)
        var model: ClipboardAudioPlayback? = ClipboardAudioPlayback(video: true, open: { _ in client })
        model?.load(url, access: original); try await wait { model?.image != nil }
        weak var weakModel = model; model = nil; XCTAssertNil(weakModel); XCTAssertTrue(client.stopped)
        scope.invalidate()
        let next = ClipboardAudioPlayback(video: true, open: { _ in XCTFail(); return client })
        next.load(url, access: original); XCTAssertFalse(next.isLoaded)
    }
    func testActualVideoViewDisplaysPixelsControlsAndClearsOnRevocation() async throws {
        _ = NSApplication.shared
        let scope = AskImagePresentationScope(), client = SyntheticVideoClient()
        let model = ClipboardAudioPlayback(video: true, open: { _ in client })
        let host = NSHostingView(rootView: ClipboardMediaPlayer(url: url, playback: model)
            .environment(\.askContextImageAccess, access(scope)).frame(width: 252, height: 190))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 252, height: 190), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { model.stop(); window.orderOut(nil); window.contentView = nil }
        try await wait { model.image != nil }; try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        var blue = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) { for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.blueComponent - color.redComponent > 0.3 { blue += 1 }
        } }
        XCTAssertGreaterThan(blue, 100)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/video-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("video-playback.png"))
        scope.setVisible(false); XCTAssertNil(model.image); XCTAssertFalse(model.isLoaded)
    }

    /// Private two-color, rotated video with NO audio track. Safe to exercise native play/end.
    static func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        input.transform = CGAffineTransform(translationX: 32, y: 0).rotated(by: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<6 {
            var value: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &value), kCVReturnSuccess)
            let buffer = try XCTUnwrap(value); CVPixelBufferLockBaseAddress(buffer, [])
            let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<32 { for x in 0..<64 {
                let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                pointer[offset] = 255; pointer[offset + 1] = index < 3 ? 255 : 0
                pointer[offset + 2] = 0; pointer[offset + 3] = index < 3 ? 0 : 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for _ in 0..<200 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 4)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
    func testRealHelperRotatedVideoFramesSeekVolumeEndAndExplicitRestartWithoutAudioTrack() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("silent.mov"); try await Self.movie(file)
        let pool = ClipboardPlaybackPool()
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/video-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("silent.mov"))
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("silent.mov"))
        let client = try await ClipboardPlaybackProcess.open(file, video: true, pool: pool, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            request.timeout = 10
            return try ManagedProcess().runBlocking(request, isCancelled: { false })
        })
        defer { client.stop() }
        let first = try await client.request(.load)
        XCTAssertEqual(first.phase, .paused); XCTAssertTrue(first.video)
        XCTAssertEqual(first.frame?.width, 32); XCTAssertEqual(first.frame?.height, 64)
        XCTAssertEqual(first.pixels?.count, 32 * 64 * 4)
        let same = try await client.request(.seek, fraction: 0)
        XCTAssertEqual(same.pixels, first.pixels)
        _ = try await client.request(.volume, fraction: 0)
        let soughtEnd = try await client.request(.seek, fraction: 1)
        XCTAssertEqual(soughtEnd.phase, .ended); XCTAssertNotNil(soughtEnd.frame)
        let afterEnd = try await client.request(.play); XCTAssertLessThan(afterEnd.elapsed, 0.3)
        _ = try await client.request(.pause)
        let later = try await client.request(.seek, fraction: 0.7)
        XCTAssertNotEqual(first.pixels, later.pixels)
        _ = try await client.request(.play)
        try await Task.sleep(for: .milliseconds(800))
        let end = try await client.request(.status); XCTAssertEqual(end.phase, .ended)
        let restarted = try await client.request(.play); XCTAssertLessThan(restarted.elapsed, 0.3)
        _ = try await client.request(.pause)
        client.stop(); try await wait { pool.activeCount == 0 }
    }
    func testVideoModeRefusesAudioOnlyAndMalformedFilesWithoutPlayback() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = try ClipboardTestSupport.makeAudioFile(named: "silent.wav", in: root, seconds: 1)
        let invalid = root.appendingPathComponent("bad.mov"); try Data("not video".utf8).write(to: invalid)
        for file in [audio, invalid] {
            let pool = ClipboardPlaybackPool(), client = try await ClipboardPlaybackProcess.open(file, video: true, pool: pool, run: { request, cancelled in
                var request = request
                request.environment["LLVM_PROFILE_FILE"] = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/video-validation/refused-%p.profraw").path
                request.timeout = 10
            return try ManagedProcess().runBlocking(request, isCancelled: { false })
            })
            do { _ = try await client.request(.load); XCTFail("Invalid video accepted") } catch {}
            client.stop(); try await wait { pool.activeCount == 0 }
        }
    }
}
