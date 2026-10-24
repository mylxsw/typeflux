import AppKit
import SwiftUI
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class RecoverableRecordingPlayback: ClipboardPlaybackClient, @unchecked Sendable {
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) async throws -> MediaPlaybackState {
        var state = MediaPlaybackState(phase: .paused, elapsed: 0, duration: 2)
        state.video = true
        state.frame = .init(width: 64, height: 32, time: 0)
        state.pixels = Data(repeating: 180, count: 64 * 32 * 4)
        return state
    }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?,
                 mix: MediaPlaybackMix?) async throws -> MediaPlaybackState {
        try await request(kind, fraction: fraction)
    }
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws {}
    func stop() {}
}

private final class RecordingPreviewAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failures: Int
    init(failures: Int = 0) { self.failures = failures }
    var calls: Int { lock.withLock { count } }
    func next() throws {
        try lock.withLock {
            count += 1
            if count <= failures { throw MediaFailure.unavailable }
        }
    }
}

@Suite("Recording preview recovery", .exclusiveUIState)
@MainActor
struct RecordingPreviewRecoveryTests {
    private func fixture(failures: Int = 0) -> ScreenRecordingCoordinatorTests.Fixture {
        let attempts = RecordingPreviewAttempts(failures: failures)
        return .init(playback: ClipboardAudioPlayback(video: true, open: { _ in
            try attempts.next()
            return RecoverableRecordingPlayback()
        }))
    }

    private func preview(_ fixture: ScreenRecordingCoordinatorTests.Fixture) async {
        await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
    }

    @Test func screenshotProcessStartsPlaybackAndReadsFinishedMovie() async throws {
        let pool = ClipboardPlaybackPool(requiresLifecycle: true)
        let run: ClipboardPlaybackProcess.Runner = { request, cancelled in
            var request = request; request.timeout = 10
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        }
        let playback = ClipboardAudioPlayback(video: true, open: { url in
            try await ClipboardPlaybackProcess.open(url, video: true, recording: true, pool: pool, run: run)
        })
        let fixture = ScreenRecordingCoordinatorTests.Fixture(playback: playback)
        let module = PlaybackModule(pool: pool, healthDirectory: fixture.root)
        // Match DI's production filtering and startup; a standalone, unrestricted test pool hid this regression.
        let registry = ModuleRegistry([module.registration].filter { FeatureRole.screenshot.modules.contains($0.id) })
        #expect(FeatureRole.screenshot.modules.contains(.mediaPlayback))
        #expect(await registry.startAll().isEmpty)
        await preview(fixture)
        #expect(fixture.model.state == .preview)
        #expect(fixture.model.playback.isLoaded && fixture.model.playback.image != nil)
        #expect(fixture.model.duration > 0 && fixture.model.canExport)
        #expect(fixture.model.error == nil)
        await fixture.clean(); await registry.shutdown()
        #expect(pool.activeCount == 0)
    }

    @Test func reloadAfterInitialFailureRestoresTimelineWithoutRecapturing() async throws {
        let fixture = fixture(failures: 1), timeline = RecordingPreviewAttempts()
        fixture.model.loadTimeline = { _ in
            try timeline.next()
            return .init(size: CGSize(width: 640, height: 360), fps: 30, fileBytes: 100_000, audio: .absent)
        }
        await preview(fixture)
        let source = try #require(fixture.model.sourceURL)
        #expect(fixture.model.playback.failed && !fixture.model.canExport)
        #expect(timeline.calls == 0)
        fixture.model.reloadPreviewPlayback(); await fixture.model.pendingTask?.value
        try await SettingsBehaviorTestSupport.wait { fixture.model.media.audio == .absent }
        #expect(fixture.model.playback.isLoaded && fixture.model.error == nil)
        #expect(fixture.model.duration == 2 && fixture.model.trimStart == 0 && fixture.model.trimEnd == 2)
        #expect(fixture.model.previewOutputSize == CGSize(width: 640, height: 360))
        #expect(fixture.model.canExport && timeline.calls == 1)
        #expect(fixture.engine.starts == 1 && fixture.engine.stops == 1)
        #expect(fixture.model.sourceURL == source && FileManager.default.fileExists(atPath: source.path))
        await fixture.clean()
    }

    @Test func reloadRetriesFailedTimelineAndKeepsTrimSpeedAndTrackChoices() async throws {
        let fixture = fixture(), timeline = RecordingPreviewAttempts(failures: 1)
        fixture.model.loadTimeline = { _ in
            try timeline.next()
            return .init(tracks: [[0.2, 0.4]], size: CGSize(width: 640, height: 360), fps: 30,
                         fileBytes: 100_000, audio: .available)
        }
        await preview(fixture)
        try await SettingsBehaviorTestSupport.wait { fixture.model.media.audio == .unavailable }
        fixture.model.trimStart = 0.2; fixture.model.trimEnd = 1.5
        fixture.model.edit.rate = 2
        fixture.model.edit.tracks = [.init(id: 0, kind: .other, waveform: [], included: false, volume: 0.3)]
        fixture.model.reloadPreviewPlayback(); await fixture.model.pendingTask?.value
        try await SettingsBehaviorTestSupport.wait { fixture.model.media.audio == .available }
        #expect(timeline.calls == 2)
        #expect(fixture.model.trimStart == 0.2 && fixture.model.trimEnd == 1.5 && fixture.model.edit.rate == 2)
        #expect(fixture.model.edit.tracks.first?.included == false)
        #expect(fixture.model.edit.tracks.first?.volume == 0.3)
        #expect(fixture.model.edit.tracks.first?.waveform == [0.2, 0.4])
        #expect(!fixture.model.isPlaying && fixture.engine.starts == 1)
        await fixture.clean()
    }

    @Test func formatSegmentsAndMoreMenuUseSharedControls() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        let previousLanguage = AppLocalization.shared.language
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer {
            NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: attribute)
            AppLocalization.shared.setLanguage(previousLanguage)
        }
        let fixture = fixture()
        fixture.model.loadTimeline = { _ in .init(size: CGSize(width: 640, height: 360), fps: 30, audio: .absent) }
        await preview(fixture)
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                try await SettingsBehaviorTestSupport.withWindow(
                    ScreenRecordingPreviewView(model: fixture.model).environment(\.interfaceStyle, style),
                    width: 920, height: 632
                ) { window, content in
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    try await Task.sleep(for: .milliseconds(100))
                    func moreButton(in view: NSView) -> NSPopUpButton? {
                        if let button = view as? NSPopUpButton,
                           button.accessibilityIdentifier() == "recording.preview.more" { return button }
                        return view.subviews.lazy.compactMap { moreButton(in: $0) }.first
                    }
                    let menu = try #require(moreButton(in: content))
                    #expect(menu.frame.size == CGSize(width: 30, height: 30))
                    #expect(menu.itemTitles.contains(L("recording.reloadPreview")))
                    #expect(menu.itemTitles.contains(L("recording.revealOriginal")))
                    #expect(menu.itemArray.dropFirst().allSatisfy { $0.state == .off })
                    for format in ScreenRecordingFormat.allCases {
                        let segment = try #require(SettingsBehaviorTestSupport.elements(in: content).first {
                            $0.value("accessibilityIdentifier") as? String ==
                                "recording.preview.format." + format.rawValue
                        })
                        try segment.press()
                        #expect(fixture.model.options.format == format)
                        #expect(window.frame.contains(segment.frame))
                        try await Task.sleep(for: .milliseconds(240))
                    }
                    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try ScreenshotSnapshotSupport.write(#require(bitmap.cgImage),
                        name: "recording-preview-controls-\(style.rawValue)-\(dark ? "dark" : "light")")
                }
            }
        }
        await fixture.clean()
    }

    @Test func failedPreviewShowsOneMessageAboveRecoveryActions() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let fixture = fixture(failures: 1)
        await preview(fixture)
        try await SettingsBehaviorTestSupport.withWindow(ScreenRecordingPreviewView(model: fixture.model),
                                                         width: 920, height: 632) { _, content in
            let nodes = SettingsBehaviorTestSupport.elements(in: content)
            let messages = nodes.filter {
                $0.role == NSAccessibility.Role.staticText.rawValue && $0.text == L("recording.previewUnavailable")
            }
            #expect(messages.count == 1)
            let reload = try SettingsBehaviorTestSupport.button(L("recording.reloadPreview"), in: content)
            let message = try #require(messages.first)
            #expect(message.frame.minY > reload.frame.maxY)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try ScreenshotSnapshotSupport.write(#require(bitmap.cgImage), name: "recording-preview-recovery")
        }
        await fixture.clean()
    }
}
