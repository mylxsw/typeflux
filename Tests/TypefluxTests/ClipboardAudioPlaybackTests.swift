import AppKit
import SwiftUI
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

private final class SilentPlayback: ClipboardPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [MediaPlaybackMessage.Kind] = []
    private var value = MediaPlaybackState(phase: .paused, elapsed: 0, duration: 2)
    private var stopped = false
    var fail = false
    var delay: UInt64 = 0
    var calls: [MediaPlaybackMessage.Kind] { lock.withLock { commands } }
    var didStop: Bool { lock.withLock { stopped } }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) async throws -> MediaPlaybackState {
        lock.withLock { commands.append(kind) }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return try lock.withLock {
            if fail { throw MediaFailure.unavailable }
            switch kind {
            case .play: if value.phase == .ended { value.elapsed = 0 }; value.phase = .playing
            case .pause: value.phase = .paused
            case .seek: value.elapsed = (fraction ?? 0) * value.duration; if value.elapsed == value.duration { value.phase = .ended }
            default: break
            }
            return value
        }
    }
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws {} // No child in this injected client.
    func stop() { lock.withLock { stopped = true } }
}
private actor PlaybackOpening {
    private var continuation: CheckedContinuation<any ClipboardPlaybackClient, Never>?
    var count = 0
    func open() async -> any ClipboardPlaybackClient { count += 1; return await withCheckedContinuation { continuation = $0 } }
    func resolve(_ client: any ClipboardPlaybackClient) { continuation?.resume(returning: client); continuation = nil }
}

@MainActor final class ClipboardAudioPlaybackTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/private/synthetic.wav")
    private func access(_ scope: AskImagePresentationScope, authorize: @escaping @MainActor () -> Bool = { true }) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: authorize)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTFail("Playback condition did not finish")
    }
    func testControlsWithoutALoadedFileDoNothing() {
        let playback = ClipboardAudioPlayback(open: { _ in XCTFail("Unexpected load"); throw MediaFailure.unavailable })
        playback.toggle(); playback.seek(to: 0.5); playback.seek(to: .nan)
        playback.load(url, access: .init())
        XCTAssertFalse(playback.isLoaded); XCTAssertFalse(playback.isPlaying); XCTAssertEqual(playback.progress, 0)
    }
    func testSilentLoadExplicitCommandsEndRestartAndNoDuplicate() async throws {
        let client = SilentPlayback(), scope = AskImagePresentationScope()
        let playback = ClipboardAudioPlayback(open: { _ in client }); defer { playback.stop() }
        playback.load(url, access: access(scope)); try await wait { playback.isLoaded }
        XCTAssertEqual(client.calls, [.load]); XCTAssertFalse(playback.isPlaying); XCTAssertEqual(playback.duration, 2)
        playback.load(url, access: access(scope)); XCTAssertEqual(client.calls, [.load])
        playback.toggle(); playback.toggle(); XCTAssertFalse(playback.isPlaying, "Only an acknowledged command changes state")
        try await wait { playback.isPlaying && !playback.isBusy }; XCTAssertEqual(client.calls.filter { $0 == .play }.count, 1)
        playback.toggle(); try await wait { !playback.isPlaying && !playback.isBusy }
        playback.seek(to: 2); try await wait { playback.progress == 1 && !playback.isBusy }
        XCTAssertEqual(playback.elapsed, 2)
        playback.toggle(); try await wait { playback.progress == 0 && playback.isPlaying && !playback.isBusy }
        playback.seek(to: -1); try await wait { !playback.isBusy }
        playback.seek(to: .infinity); XCTAssertFalse(playback.isBusy)
        playback.stop(); XCTAssertFalse(playback.isLoaded); XCTAssertFalse(playback.isPlaying); XCTAssertEqual(playback.duration, 0); XCTAssertTrue(client.didStop)
    }
    func testFailureDoesNotReplayOrBlessOldAccess() async throws {
        let client = SilentPlayback(), scope = AskImagePresentationScope(); client.fail = true
        let playback = ClipboardAudioPlayback(open: { _ in client })
        let original = access(scope); playback.load(url, access: original)
        try await wait { playback.failed }
        playback.load(url, access: original); playback.toggle()
        XCTAssertEqual(client.calls, [.load]); XCTAssertFalse(playback.isLoaded)
        scope.invalidate(); XCTAssertFalse(playback.failed); XCTAssertFalse(original.allows())
        playback.load(url, access: original); XCTAssertEqual(client.calls, [.load])
    }
    func testUncooperativeLoadIsBoundedUntilActualReturnAndOwnerReleaseStops() async throws {
        let gate = PlaybackOpening(), client = SilentPlayback(), scope = AskImagePresentationScope()
        var playback: ClipboardAudioPlayback? = ClipboardAudioPlayback(open: { _ in await gate.open() })
        playback?.load(url, access: access(scope))
        for _ in 0..<100 { if await gate.count > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        scope.invalidate(); playback?.load(url, access: access(scope))
        let count = await gate.count; XCTAssertEqual(count, 1)
        weak var released = playback; playback = nil; XCTAssertNil(released)
        await gate.resolve(client); try await wait { client.didStop }
    }
    func testLatestReplacementWaitsForCancelledFactoryAndNeverResumesPlayback() async throws {
        let gate = PlaybackOpening(), first = SilentPlayback(), second = SilentPlayback(), scope = AskImagePresentationScope()
        let playback = ClipboardAudioPlayback(open: { url in
            if url.lastPathComponent == "synthetic.wav" { return await gate.open() }
            return second
        }); defer { playback.stop() }
        playback.load(url, access: access(scope))
        for _ in 0..<100 { if await gate.count > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        playback.load(URL(fileURLWithPath: "/private/new.wav"), access: access(scope))
        XCTAssertFalse(playback.isLoaded); XCTAssertTrue(second.calls.isEmpty)
        await gate.resolve(first); try await wait { playback.isLoaded }
        XCTAssertTrue(first.didStop); XCTAssertEqual(second.calls, [.load]); XCTAssertFalse(playback.isPlaying)
    }
    func testLateReplyAndAuthorizationChangeClearWithoutAnotherCommand() async throws {
        let client = SilentPlayback(), scope = AskImagePresentationScope(); client.delay = 100_000_000
        var allowed = true
        let playback = ClipboardAudioPlayback(open: { _ in client })
        playback.load(url, access: access(scope, authorize: { allowed }))
        try await wait { !client.calls.isEmpty }; allowed = false
        try await wait { client.didStop }; XCTAssertFalse(playback.isLoaded); XCTAssertEqual(client.calls, [.load])
        playback.toggle(); XCTAssertFalse(playback.isBusy)
    }
    func testPanelHideSelectionDeletionAndAccountStopActualOwners() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = ClipboardPanelModel()
        let entry = ClipboardTestSupport.entry(.audio, filePaths: [url.path])
        let second = ClipboardTestSupport.entry(.audio, filePaths: ["/private/other.wav"])
        model.reset(entries: [entry, second])
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "playback-" + UUID().uuidString)!)
        let controller = ClipboardPanelController(settingsStore: settings, thumbnailDecoder: { _, _ in throw MediaFailure.unavailable })
        defer { controller.dismiss() }
        for action in 0..<4 {
            model.reset(entries: [entry, second]); controller.present(model)
            let client = SilentPlayback(), playback = ClipboardAudioPlayback(open: { _ in client })
            playback.load(url, access: controller.thumbnails.access(for: entry)); try await wait { playback.isLoaded }
            switch action {
            case 0: controller.presentedWindow?.orderOut(nil)
            case 1: model.selectedIndex = model.selectedIndex == 0 ? 1 : 0
            case 2: model.replaceEntries([])
            default: NotificationCenter.default.post(name: .authDidLogout, object: nil)
            }
            XCTAssertFalse(playback.isLoaded, "Action \(action) should clear playback")
            XCTAssertTrue(client.didStop, "Action \(action) should stop its client")
        }
    }
    func testScopeObserverAdmissionRefusesSeventeenthLoad() async throws {
        let scope = AskImagePresentationScope()
        let values = (0..<17).map { _ in ClipboardAudioPlayback(open: { _ in SilentPlayback() }) }
        for value in values { value.load(url, access: access(scope)) }
        try await wait { values.prefix(16).allSatisfy(\.isLoaded) }
        XCTAssertTrue(values[16].failed); scope.invalidate(); XCTAssertTrue(values.allSatisfy { !$0.isLoaded })
    }
    func testUnavailablePlayerPresentationAndClose() async throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = previousAppearance }
        let scope = AskImagePresentationScope()
        let playback = ClipboardAudioPlayback(open: { _ in throw MediaFailure.unavailable })
        let view = ClipboardAudioPlayerView(url: url, duration: nil, playback: playback)
            .environment(\.askContextImageAccess, access(scope)).frame(width: 360, height: 60).padding().background(Color.white).preferredColorScheme(.light)
        let host = NSHostingView(rootView: view), window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); host.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.isReleasedWhenClosed = false; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; playback.stop() }
        try await wait { playback.failed }
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        var visible = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.8 { visible += 1 }
        } }
        XCTAssertGreaterThan(visible, 30, "The unavailable control and waveform must actually render")
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/playback-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("audio-playback.png"))
        scope.setVisible(false); XCTAssertFalse(playback.failed); XCTAssertFalse(playback.isLoaded)
    }
}
