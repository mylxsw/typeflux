import AppKit
import AVFoundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenRecordingRedesignTests {
    @Test func `direct framing rejects tiny regions and preserves selected target`() async {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.select(ScreenRecordingChoice(
            id: "region",
            title: "Region",
            target: .region(displayID: 1, rect: CGRect(x: 0, y: 0, width: 39, height: 100)),
            frame: CGRect(x: 0, y: 0, width: 39, height: 100)
        ))
        #expect(!fixture.model.canStart)
        fixture.model.select(ScreenRecordingChoice(
            id: "region",
            title: "Region",
            target: .region(displayID: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 2
        ))
        #expect(fixture.model.canStart)
        #expect(fixture.model.outputSize == CGSize(width: 200, height: 200))
        fixture.model.options.format = .gif
        #expect(fixture.model.outputSummary.contains("10 FPS"))
        #expect(fixture.model.outputSummary.contains(L("recording.silent")))
        await fixture.clean()
    }

    @Test func `restart discards previous take and starts one fresh session`() async {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        let first = fixture.engine.url
        fixture.model.togglePause()
        fixture.model.restart()
        await fixture.model.pendingTask?.value
        await fixture.model.pendingTask?.value
        #expect(fixture.engine.starts == 2)
        #expect(fixture.engine.cancellations == 1)
        #expect(fixture.engine.url != first)
        #expect(fixture.model.state == .recording)
        fixture.model.restart()
        await fixture.model.pendingTask?.value
        await fixture.model.pendingTask?.value
        #expect(fixture.engine.starts == 3)
        await fixture.clean()
    }

    @Test func `cancelling a queued restart prevents a new take`() async {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.restart()
        fixture.model.cancel()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .idle)
        #expect(fixture.engine.starts == 1)
        await fixture.clean()
    }

    @Test func `countdown can skip immediately or return to selection`() async {
        let fixture = ScreenRecordingCoordinatorTests.Fixture(wait: { try await Task.sleep(for: .seconds(30)) })
        await fixture.setup()
        fixture.model.options.countdown = 10
        fixture.model.start()
        await Task.yield()
        fixture.model.skipCountdown()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .recording)
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        await fixture.clean()
        let second = ScreenRecordingCoordinatorTests.Fixture(wait: { try await Task.sleep(for: .seconds(30)) })
        await second.setup()
        second.model.start()
        await Task.yield()
        second.model.returnToSelection()
        await second.model.pendingTask?.value
        #expect(second.model.state == .setup)
        #expect(second.engine.starts == 0)
        await second.clean()
    }

    @Test func `preflight permissions update only the enabled input`() async {
        let denied = ScreenRecordingCoordinatorTests
            .Fixture(authorize: { _ in throw ScreenRecordingFailure.cameraPermission })
        await denied.setup()
        denied.model.setDevice(.video, enabled: true)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(denied.model.options.camera)
        #expect(!denied.model.canStart)
        denied.model.setDevice(.video, enabled: false)
        #expect(denied.model.permissionFailure == nil)
        #expect(denied.model.canStart)
        denied.model.setDevice(.audio, enabled: false)
        #expect(!denied.model.options.microphone)
        await denied.clean()
    }

    @Test func `player respects trim and named exports copy a file URL`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        fixture.model.setTrimStart(0.2)
        fixture.model.setTrimEnd(0.9)
        #expect(fixture.model.selectionDuration >= 0.5)
        fixture.model.seek(0)
        try await fixture.waitForPlayback { !fixture.model.playback.isBusy }
        fixture.model.togglePlayback()
        try await fixture.waitForPlayback { fixture.model.isPlaying && !fixture.model.playback.isBusy }
        #expect(fixture.model.isPlaying)
        fixture.model.togglePlayback()
        try await fixture.waitForPlayback { !fixture.model.isPlaying && !fixture.model.playback.isBusy }
        #expect(!fixture.model.isPlaying)
        fixture.model.fileName = "../Demo"
        fixture.model.outputDirectory = fixture.root.appendingPathComponent("chosen")
        fixture.model.export(copy: true)
        await fixture.model.pendingTask?.value
        let url = try #require(fixture.model.savedURL)
        #expect(url.lastPathComponent == "..-Demo.mp4")
        #expect(url.deletingLastPathComponent().resolvingSymlinksInPath().path == fixture.model.outputDirectory?
            .resolvingSymlinksInPath().path)
        #expect(fixture.copiedURL == url)
        fixture.model.finishSavedPresentation()
        #expect(fixture.model.state == .idle)
        await fixture.clean()
    }

    @Test func `recovery loads original options and deleting only affects owned sessions`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        let files = ScreenRecordingFiles(root: fixture.root.appendingPathComponent("sessions"))
        var options = ScreenRecordingOptions()
        options.format = .gif
        let session = try files.createSession(options: options)
        let url = session.appendingPathComponent("source.mov")
        try await ScreenRecordingMediaTests.makeMovie(at: url, withAudio: true)
        #expect(fixture.model.findRecoverableSources()
            .map { $0.resolvingSymlinksInPath().path } == [url.resolvingSymlinksInPath().path])
        fixture.model.recover(url)
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .preview)
        #expect(fixture.model.options.format == .gif)
        fixture.model.keepFirstGIFSegment()
        #expect(fixture.model.canExport)
        let metadata = try await ScreenRecordingPreviewMedia.load(url, loader: ScreenRecordingTimelineLoader(worker: MediaWorker()))
        #expect(metadata.thumbnails.count == 10)
        #expect(metadata.size.width > 0)
        #expect(!metadata.waveform.isEmpty)
        #expect(metadata.fileBytes > 0)
        fixture.model.discardRecovered(fixture.root.appendingPathComponent("outside/source.mov"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        await fixture.clean()
    }
}
