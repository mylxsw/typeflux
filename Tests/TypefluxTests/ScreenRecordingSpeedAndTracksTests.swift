import AppKit
import AVFoundation
import Foundation
import ImageIO
import Testing
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

@Suite("Screen recording speed and audio tracks", .exclusiveUIState)
@MainActor
struct ScreenRecordingSpeedAndTracksTests {
    // MARK: Protocol

    @Test func `export requests bound speed and track volumes and keep older requests decodable`() throws {
        try MediaRecordingExport(format: .mp4, start: 0, end: 10, rate: 4, volumes: [1, 0]).validate()
        try MediaRecordingExport(format: .gif, start: 0, end: 60, rate: 2).validate()
        for request in [
            MediaRecordingExport(format: .mp4, start: 0, end: 10, rate: 0.25),
            MediaRecordingExport(format: .mp4, start: 0, end: 10, rate: 5),
            MediaRecordingExport(format: .mp4, start: 0, end: 10, rate: .nan),
            MediaRecordingExport(format: .mp4, start: 0, end: 10, volumes: [1.5]),
            MediaRecordingExport(format: .mp4, start: 0, end: 10, volumes: [-0.1]),
            MediaRecordingExport(format: .mp4, start: 0, end: 10, volumes: [.nan]),
            MediaRecordingExport(format: .mp4, start: 0, end: 10, volumes: Array(repeating: 1, count: 9)),
            MediaRecordingExport(format: .gif, start: 0, end: 60, rate: 1.5)
        ] {
            #expect(throws: MediaFailure.invalidProtocol) { try request.validate() }
        }
        let request = MediaRecordingExport(format: .gif, start: 1, end: 41, rate: 2, volumes: [0.5])
        #expect(request.outputDuration == 20)
        #expect(try JSONDecoder().decode(MediaRecordingExport.self, from: JSONEncoder().encode(request)) == request)
        let legacy = #"{"version":1,"id":"\#(UUID().uuidString)","format":"mp4","start":0,"end":2}"#
        let decoded = try JSONDecoder().decode(MediaRecordingExport.self, from: Data(legacy.utf8))
        #expect(decoded.rate == 1 && decoded.volumes == nil)
        #expect(try JSONEncoder().encode(MediaRecordingExport(format: .mp4, start: 0, end: 1, rate: 1.25,
                                                               volumes: Array(repeating: 0.75, count: 8))).count <= 1024)
    }

    @Test func `playback mix is a dedicated validated command`() throws {
        let id = UUID(), mix = MediaPlaybackMix(rate: 2, volumes: [1, 0])
        try MediaPlaybackMessage(id: id, sequence: 1, kind: .mix, mix: mix).validate()
        try MediaPlaybackMessage(id: id, sequence: 1, kind: .mix, mix: .init(rate: 0.5, volumes: [])).validate()
        for message in [
            MediaPlaybackMessage(id: id, sequence: 1, kind: .mix),
            MediaPlaybackMessage(id: id, sequence: 1, kind: .play, mix: mix),
            MediaPlaybackMessage(id: id, sequence: 1, kind: .mix, mix: .init(rate: 8, volumes: [])),
            MediaPlaybackMessage(id: id, sequence: 1, kind: .mix, mix: .init(rate: 1, volumes: [2])),
            MediaPlaybackMessage(id: id, sequence: 1, kind: .mix, mix: .init(rate: 1, volumes: Array(repeating: 1, count: 9)))
        ] {
            #expect(throws: MediaFailure.invalidProtocol) { try message.validate() }
        }
        let encoded = try JSONEncoder().encode(MediaPlaybackMessage(id: id, sequence: 1, kind: .mix,
            mix: .init(rate: 0.75, volumes: Array(repeating: 0.33, count: 8))))
        #expect(encoded.count <= MediaPlaybackMessage.maximumBytes)
    }

    @Test func `timeline track waveforms are bounded and only sent with available audio`() throws {
        let rasters = Array(repeating: MediaRaster(width: 200, height: 120), count: 10)
        let peaks = [Float](repeating: 0.5, count: 160)
        try MediaRecordingTimeline(duration: 2, width: 100, height: 80, fps: 30, rasters: rasters,
                                   audio: .available, waveform: peaks, tracks: [peaks, peaks]).validate()
        try MediaRecordingTimeline(duration: 2, width: 100, height: 80, fps: 30, rasters: rasters,
                                   audio: .available, waveform: peaks).validate()
        for timeline in [
            MediaRecordingTimeline(duration: 2, width: 100, height: 80, fps: 30, rasters: rasters,
                                   audio: .absent, tracks: [peaks]),
            MediaRecordingTimeline(duration: 2, width: 100, height: 80, fps: 30, rasters: rasters,
                                   audio: .available, waveform: peaks, tracks: [Array(peaks.prefix(10))]),
            MediaRecordingTimeline(duration: 2, width: 100, height: 80, fps: 30, rasters: rasters,
                                   audio: .available, waveform: peaks, tracks: [peaks.map { _ in 2 }]),
            MediaRecordingTimeline(duration: 2, width: 100, height: 80, fps: 30, rasters: rasters,
                                   audio: .available, waveform: peaks, tracks: Array(repeating: peaks, count: 9))
        ] {
            #expect(throws: MediaFailure.invalidProtocol) { try timeline.validate() }
        }
    }

    // MARK: Native export

    @Test func `native export applies speed and leaves out muted tracks`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await ScreenRecordingMediaTests.makeMovie(at: source, withAudio: true)
        func encode(_ request: MediaRecordingExport) async throws -> URL {
            let job = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: source, to: job.appendingPathComponent("input.mov"))
            _ = try await MediaRecordingExportDecoder.encode(request, directory: job) { _ in }
            return job.appendingPathComponent(request.outputName)
        }
        let fast = AVURLAsset(url: try await encode(.init(format: .mp4, start: 0, end: 1, rate: 2, volumes: [1, 0])))
        #expect(abs(try await fast.load(.duration).seconds - 0.5) <= 0.05)
        #expect(try await fast.loadTracks(withMediaType: .audio).count == 1)
        let silent = AVURLAsset(url: try await encode(.init(format: .mp4, start: 0, end: 1, volumes: [0, 0])))
        #expect(try await silent.loadTracks(withMediaType: .audio).isEmpty)
        #expect(abs(try await silent.load(.duration).seconds - 1) <= 0.05)
        let slow = AVURLAsset(url: try await encode(.init(format: .mp4, start: 0.2, end: 0.8, rate: 0.5)))
        #expect(abs(try await slow.load(.duration).seconds - 1.2) <= 0.05)
        let gif = try await encode(.init(format: .gif, start: 0, end: 1, rate: 2))
        #expect(CGImageSourceGetCount(try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))) == 5)
        await #expect(throws: MediaFailure.invalidProtocol) {
            _ = try await encode(.init(format: .mp4, start: 0, end: 1, volumes: [1]))
        }
    }

    @Test func `timeline decoder reports one waveform per audio track`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for withAudio in [true, false] {
            let input = directory.appendingPathComponent("input")
            try? FileManager.default.removeItem(at: input)
            try await ScreenRecordingMediaTests.makeMovie(at: directory.appendingPathComponent("movie.mov"), withAudio: withAudio)
            try FileManager.default.moveItem(at: directory.appendingPathComponent("movie.mov"), to: input)
            let response = try await MediaRecordingTimelineDecoder.decode(.init(operation: .recordingTimeline), directory: directory)
            let timeline = try #require(response.timeline)
            if withAudio {
                #expect(timeline.audio == .available)
                #expect(timeline.tracks.count == 2)
                #expect(timeline.tracks.allSatisfy { $0.count == 160 && $0.contains { $0 > 0 } })
                // The combined waveform is the loudest of the tracks at every point.
                #expect(timeline.waveform == zip(timeline.tracks[0], timeline.tracks[1]).map { max($0, $1) })
            } else {
                #expect(timeline.audio == .absent && timeline.tracks.isEmpty)
            }
            for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where file.hasPrefix("raster") {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }

    // MARK: Edit model

    @Test func `edit model maps volumes speed presets and GIF fitting`() throws {
        var edit = ScreenRecordingEdit()
        #expect(edit.isDefault && edit.volumes == nil && edit.playbackMix == MediaPlaybackMix(rate: 1, volumes: []))
        edit.tracks = [.init(id: 0, kind: .systemAudio, waveform: []), .init(id: 1, kind: .microphone, waveform: [])]
        edit.tracks[1].included = false
        edit.tracks[0].volume = 0.4
        #expect(edit.volumes == [0.4, 0])
        #expect(edit.includedTracks.map(\.id) == [0])
        #expect(!edit.isDefault)
        edit.rate = 2
        #expect(edit.outputDuration(48) == 24)
        #expect(edit.gifSourceEnd(from: 5) == 65)
        #expect(edit.playbackMix == MediaPlaybackMix(rate: 2, volumes: [0.4, 0]))
        edit.rate = 1
        #expect(edit.fittingGIFRate(selection: 48) == 2)
        #expect(edit.fittingGIFRate(selection: 30) == 1.25)
        #expect(edit.fittingGIFRate(selection: 200) == nil)
        #expect(ScreenRecordingEdit.rateTitle(1) == "1×")
        #expect(ScreenRecordingEdit.rateTitle(0.75) == "0.75×")
        #expect(ScreenRecordingEdit.rateTitle(1.5) == "1.5×")
    }

    @Test func `track kinds follow the writer order and fall back to numbers`() {
        AppLocalization.shared.setLanguage(.english)
        var options = ScreenRecordingOptions()
        options.systemAudio = true; options.microphone = true
        let both = ScreenRecordingAudioTrack.tracks(waveforms: [[0.1], [0.2]], options: options)
        #expect(both.map(\.kind) == [.systemAudio, .microphone])
        #expect(both.map(\.title) == [L("recording.systemAudio"), L("recording.microphone")])
        options.systemAudio = false
        #expect(ScreenRecordingAudioTrack.tracks(waveforms: [[0.1]], options: options).map(\.kind) == [.microphone])
        let mismatch = ScreenRecordingAudioTrack.tracks(waveforms: [[0.1], [0.2]], options: options)
        #expect(mismatch.map(\.kind) == [.other, .other])
        #expect(mismatch[1].title == L("recording.trackNumber", 2))
        options.format = .gif
        #expect(ScreenRecordingAudioTrack.tracks(waveforms: [[0.1]], options: options).map(\.kind) == [.other])
    }

    @Test func `trim validation measures GIF length after the speed change`() {
        #expect(throws: Never.self) {
            try ScreenRecordingTrim(start: 0, end: 60, rate: 2).validated(duration: 90, format: .gif)
        }
        #expect(throws: ScreenRecordingFailure.invalidRange) {
            try ScreenRecordingTrim(start: 0, end: 60, rate: 1.5).validated(duration: 90, format: .gif)
        }
        #expect(throws: ScreenRecordingFailure.invalidRange) {
            try ScreenRecordingTrim(start: 0, end: 10, rate: 0).validated(duration: 90, format: .mp4)
        }
    }

    @Test func `destination folders list the current folder once and first`() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL
        let custom = URL(fileURLWithPath: "/tmp/typeflux-folder-test", isDirectory: true)
        let folders = ScreenRecordingLayout.destinationFolders(current: custom)
        #expect(folders.first == custom.standardizedFileURL)
        #expect(folders.contains(desktop))
        #expect(Set(folders).count == folders.count)
        #expect(ScreenRecordingLayout.destinationFolders(current: desktop).filter { $0 == desktop }.count == 1)
    }

    @Test func `timeline ruler steps keep labels apart`() {
        #expect(ScreenRecordingTimelineView.rulerStep(width: 900, duration: 4.6) == 0.5)
        #expect(ScreenRecordingTimelineView.rulerStep(width: 900, duration: 48) == 5)
        #expect(ScreenRecordingTimelineView.rulerStep(width: 900, duration: 7200) == 600)
        #expect(ScreenRecordingTimelineView.rulerStep(width: 0, duration: 10) == 1)
    }

    // MARK: Coordinator

    /// A finished preview of a recording with system audio and microphone tracks. The playback helper
    /// is real; the timeline is injected because its media worker is unavailable in unit tests.
    private func audioPreview(exporter: (any ScreenRecordingExporting)? = nil) async throws -> ScreenRecordingCoordinatorTests.Fixture {
        let fixture = ScreenRecordingCoordinatorTests.Fixture(exporter: exporter)
        fixture.engine.movie = { try await ScreenRecordingMediaTests.makeMovie(at: $0, withAudio: true) }
        let peaks = [Float](repeating: 0.3, count: 160)
        fixture.model.loadTimeline = { _ in
            ScreenRecordingPreviewMedia(waveform: peaks, tracks: [peaks, peaks], fps: 10, fileBytes: 400_000, audio: .available)
        }
        fixture.model.options.systemAudio = true; fixture.model.options.microphone = true
        await fixture.recording()
        fixture.model.stop(); await fixture.model.pendingTask?.value
        for _ in 0 ..< 500 where fixture.model.media.audio == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await fixture.waitForPlayback { fixture.model.playback.isLoaded && !fixture.model.playback.isBusy }
        return fixture
    }

    @Test func `speed and tracks drive the preview mix, summary, size and export`() async throws {
        AppLocalization.shared.setLanguage(.english)
        let exporter = RecordingExporter()
        let fixture = try await audioPreview(exporter: exporter)
        let model = fixture.model
        #expect(model.state == .preview && model.edit.isDefault && model.edit.rate == 1)
        #expect(model.media.audio == .available)
        #expect(model.edit.tracks.map(\.kind) == [.systemAudio, .microphone])
        #expect(model.edit.tracks.allSatisfy { $0.waveform.count == 160 })
        #expect(model.playback.mix == nil)
        #expect(model.frameRate > 0)

        model.setRate(3.3)
        #expect(model.edit.rate == 1 && model.playback.mix == nil)
        model.setRate(2)
        #expect(model.playback.mix == MediaPlaybackMix(rate: 2, volumes: [1, 1]))
        #expect(abs(model.outputDuration - model.selectionDuration / 2) < 0.0001)
        #expect(model.exportSummary.contains("2×"))
        model.stepRate(by: 1); #expect(model.edit.rate == 3)
        model.stepRate(by: 10); #expect(model.edit.rate == 3)
        model.stepRate(by: -2); #expect(model.edit.rate == 1.5)
        model.setRate(1)
        #expect(model.playback.mix == MediaPlaybackMix(rate: 1, volumes: [1, 1]))
        #expect(!model.exportSummary.contains("×"))

        model.setTrack(9, included: false)
        #expect(model.edit.tracks.allSatisfy { $0.included })
        let withAudio = model.estimatedBytes
        model.setTrack(1, included: false)
        model.setTrack(0, volume: 7)
        #expect(model.edit.volumes == [1, 0])
        #expect(model.exportSummary.contains(L("recording.systemAudio")) && !model.exportSummary.contains(L("recording.microphone")))
        model.setTrack(0, included: false)
        #expect(model.exportSummary.contains(L("recording.allTracksOff")))
        #expect(model.estimatedBytes < withAudio)
        model.setTrack(0, included: true, volume: 0.5)
        model.setRate(1.5)
        #expect(model.playback.mix == MediaPlaybackMix(rate: 1.5, volumes: [0.5, 0]))
        // The helper accepts the mix and keeps playing at the new speed.
        model.togglePlayback()
        try await fixture.waitForPlayback { model.isPlaying || model.playback.failed }
        #expect(!model.playback.failed)
        model.togglePlayback()
        try await fixture.waitForPlayback { !model.isPlaying && !model.playback.isBusy }

        model.options.format = .gif
        #expect(!model.gifTooLong)
        model.keepFirstGIFSegment()
        #expect(model.trimEnd == model.duration)
        model.options.format = .mp4
        model.export(); await model.pendingTask?.value
        let trim = try #require(exporter.trims.first)
        #expect(trim.rate == 1.5 && trim.volumes == [0.5, 0])
        await fixture.clean()
    }

    @Test func `a new recording resets speed and track choices`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop(); await fixture.model.pendingTask?.value
        fixture.model.setRate(2)
        let source = try #require(fixture.model.sourceURL)
        fixture.model.reloadPreviewPlayback(); await fixture.model.pendingTask?.value
        #expect(fixture.model.edit.rate == 2 && fixture.model.playback.mix?.rate == 2)
        fixture.model.cancel(); await fixture.model.pendingTask?.value
        await fixture.recording()
        fixture.model.stop(); await fixture.model.pendingTask?.value
        #expect(fixture.model.sourceURL != source)
        #expect(fixture.model.edit == ScreenRecordingEdit() && fixture.model.playback.mix == nil)
        await fixture.clean()
    }

    @Test func `editor keys step frames and change speed`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop(); await fixture.model.pendingTask?.value
        let presenter = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
        presenter.show(fixture.model)
        let window = try #require(presenter.window)
        try await fixture.waitForPlayback { !fixture.model.playback.isBusy }
        #expect(try presenter.handleEditorKey(key(124, "", window: window)))
        let frame = 1 / Double(fixture.model.frameRate)
        try await fixture.waitForPlayback { abs(fixture.model.currentTime - frame) < 0.01 && !fixture.model.playback.isBusy }
        #expect(abs(fixture.model.currentTime - frame) < 0.01)
        #expect(try presenter.handleEditorKey(key(123, "", window: window, flags: .shift)))
        try await fixture.waitForPlayback { fixture.model.currentTime == 0 && !fixture.model.playback.isBusy }
        #expect(fixture.model.currentTime == 0)
        #expect(try presenter.handleEditorKey(key(30, "]", window: window)))
        #expect(fixture.model.edit.rate == 1.25)
        #expect(try presenter.handleEditorKey(key(33, "[", window: window)))
        #expect(try presenter.handleEditorKey(key(33, "[", window: window)))
        #expect(fixture.model.edit.rate == 0.75)
        #expect(try !presenter.handleEditorKey(key(30, "]", window: window, flags: .command)))
        #expect(try !presenter.handleEditorKey(key(0, "a", window: window)))
        presenter.hide(); await presenter.deviceTask?.value
        await fixture.clean()
    }

    @Test func `editor renders tracks speed and GIF states without layout loss`() async throws {
        AppLocalization.shared.setLanguage(.english)
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = try await audioPreview()
        fixture.model.setTrack(1, included: false)
        fixture.model.setRate(2)
        #expect(ScreenRecordingTimelineView.laneCount(fixture.model) == 2)
        #expect(ScreenRecordingTimelineView.height(fixture.model) == CGFloat(18 + 52 + 2 * 28))
        for format in ScreenRecordingFormat.allCases {
            fixture.model.options.format = format
            try await SettingsBehaviorTestSupport.withWindow(ScreenRecordingPreviewView(model: fixture.model),
                                                             width: 760, height: 600) { window, content in
                let nodes = SettingsBehaviorTestSupport.elements(in: content)
                let speed = try #require(nodes.first { $0.value("accessibilityIdentifier") as? String == "recording.preview.speed" })
                #expect(window.frame.contains(speed.frame))
                let tracks = try #require(nodes.first { $0.value("accessibilityIdentifier") as? String == "recording.preview.tracks" })
                #expect((tracks.value("isAccessibilityEnabled") as? Bool) == (format == .mp4))
                let lane = nodes.first { $0.value("accessibilityIdentifier") as? String == "recording.track.1" }
                #expect((lane != nil) == (format == .mp4))
            }
            for dark in [true, false] {
                let editor = try await ScreenshotSnapshotSupport.bitmap(
                    of: ScreenRecordingPreviewView(model: fixture.model).frame(width: 920, height: 660), dark: dark
                )
                try ScreenshotSnapshotSupport.write(try #require(editor.cgImage),
                    name: "recording-editor-tracks-\(format.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        fixture.model.options.format = .mp4
        fixture.model.edit.tracks = []
        #expect(ScreenRecordingTimelineView.laneCount(fixture.model) == 1)
        await fixture.clean()
    }

    private func key(_ code: UInt16, _ text: String, window: NSWindow,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: text,
                                      charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
}

/// Records what the coordinator asked to export, then writes a placeholder file.
private final class RecordingExporter: ScreenRecordingExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScreenRecordingTrim] = []
    var trims: [ScreenRecordingTrim] { lock.withLock { values } }
    func export(source _: URL, destination: URL, format _: ScreenRecordingFormat, trim: ScreenRecordingTrim,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { values.append(trim) }
        try Data([1, 2, 3]).write(to: destination)
        progress(1)
    }
}
