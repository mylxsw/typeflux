import AppKit
import AVFoundation
import Testing
@testable import Typeflux

@Suite("Screen recording coordinator", .exclusiveUIState)
@MainActor
struct ScreenRecordingCoordinatorTests {
    final class Engine: ScreenRecordingEngine {
        var onError: (@MainActor (Error) -> Void)?
        var seconds: Double = 1
        var starts = 0
        var stops = 0
        var cancellations = 0
        var pauses: [Bool] = []
        var startError: Error?
        var startGate: CheckedContinuation<Void, Never>?
        var blocksStart = false
        var movie: (URL) async throws -> Void = { try await ScreenRecordingMediaTests.makeMovie(at: $0) }
        var url: URL?
        func start(target _: ScreenRecordingTarget, options _: ScreenRecordingOptions, url: URL) async throws {
            starts += 1
            self.url = url
            if blocksStart {
                await withCheckedContinuation { startGate = $0 }
            }
            if let startError {
                throw startError
            }
        }

        func setPaused(_ paused: Bool) {
            pauses.append(paused)
        }

        func elapsed() async -> Double {
            seconds
        }

        func stop() async throws -> URL {
            stops += 1
            let url = try #require(url)
            try await movie(url)
            return url
        }

        func cancel() async {
            cancellations += 1
        }
    }

    final class Overlay: ScreenshotOverlayPresenting {
        var event: ((ScreenshotOverlayEvent) -> Void)?
        var dismissals = 0
        func present(_: ScreenSnapshot, onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
            event = onEvent
        }

        func selectFullScreen() {}
        func startScrollCapture() {}
        func finish(_ action: ScreenshotOutputAction) {
            event?(.finish(action, displayID: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 80)))
        }

        func dismiss() {
            event = nil; dismissals += 1
        }
    }

    struct Exporter: ScreenRecordingExporting {
        var fails = false
        func export(source _: URL, destination: URL, format _: ScreenRecordingFormat, trim _: ScreenRecordingTrim,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
            if fails {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try Data([1, 2, 3]).write(to: destination)
            progress(1)
        }
    }

    @MainActor
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "recording-coordinator-" + UUID().uuidString
        let engine = Engine()
        let overlay = Overlay()
        let permission = FakeScreenCapturePermission(granted: true)
        let capture = FakeScreenCapturer(.success(ScreenSnapshot(displays: [], windows: [])))
        var presentations = 0
        var dismissals = 0
        var copiedURL: URL?
        var borders: [ScreenRecordingTarget?] = []
        let model: ScreenRecordingCoordinator
        init(exportFails: Bool = false, authorize: @escaping (ScreenRecordingOptions) async throws -> Void = { _ in },
             wait: @escaping () async throws -> Void = {}, playback: ClipboardAudioPlayback? = nil) {
            model = ScreenRecordingCoordinator(
                permission: permission,
                capture: capture,
                overlay: overlay,
                engine: engine,
                exporter: Exporter(fails: exportFails),
                files: ScreenRecordingFiles(root: root.appendingPathComponent("sessions")),
                defaults: UserDefaults(suiteName: suite)!,
                saveDirectory: { [root] in root.appendingPathComponent("saved") },
                authorizeDevices: authorize,
                loadChoices: {
                    [
                        ScreenRecordingChoice(
                            id: "display",
                            title: "Display",
                            target: .display(1), frame: CGRect(x: 0, y: 0, width: 1200, height: 720), scale: 2
                        ),
                        ScreenRecordingChoice(
                            id: "window",
                            title: "Window",
                            target: .window(2), frame: CGRect(x: 100, y: 100, width: 600, height: 400), scale: 2
                        )
                    ]
                },
                waitSecond: wait, playback: playback ?? ClipboardAudioPlayback(video: true, open: { url in
                    try await ClipboardPlaybackProcess.open(url, video: true, recording: true, run: { request, _ in
                        var request = request; request.timeout = 10
                        return try ManagedProcess().runBlocking(request, isCancelled: { false })
                    })
                })
            )
            model.present = { [weak self] _ in self?.presentations += 1 }
            model.dismiss = { [weak self] in self?.dismissals += 1 }
            model.copyPublishedFile = { [weak self] in self?.copiedURL = $0 }
            model.showBorder = { [weak self] target in self?.borders.append(target) }
        }

        func setup() async {
            model.show(); await model.pendingTask?.value; model.selectSourceKind(.display)
        }

        func recording() async {
            await setup(); model.options.countdown = 0; model.start(); await model.pendingTask?.value
        }

        func clean() async {
            model.cancel()
            await model.pendingTask?.value
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func waitForPlayback(_ predicate: () -> Bool) async throws {
            for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(predicate())
        }
    }

    @Test func `denied permission only prompts on explicit open`() async {
        let fixture = Fixture()
        fixture.permission.granted = false
        #expect(fixture.permission.onceRequests == 0)
        await fixture.setup()
        #expect(fixture.model.error != nil)
        #expect(fixture.model.choices.isEmpty)
        #expect(fixture.permission.onceRequests == 1)
        fixture.model.start()
        #expect(fixture.engine.starts == 0)
        fixture.model.openPermissions()
        #expect(fixture.permission.settingsOpened == 1)
        fixture.permission.granted = true
        fixture.model.reloadChoices()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.choices.count == 2)
        await fixture.clean()
    }

    @Test func `selection reuses overlay without saving screenshot`() async {
        let fixture = Fixture()
        await fixture.setup()
        fixture.model.selectRegion()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .selecting)
        fixture.overlay.event?(.committed)
        #expect(fixture.model.state == .setup)
        #expect(fixture.model.selectedID == "region")
        #expect(fixture.model.choices.first?.target == .region(
            displayID: 1,
            rect: CGRect(x: 10, y: 20, width: 100, height: 80)
        ))
        #expect(fixture.capture.requests.count == 1)
        fixture.model.selectRegion()
        await fixture.model.pendingTask?.value
        fixture.overlay.event?(.cancelled)
        #expect(fixture.model.state == .setup)
        await fixture.clean()
    }

    @Test func `capture mutual exclusion and repeated open`() async {
        let fixture = Fixture()
        fixture.model.isOtherCaptureActive = { true }
        fixture.model.show()
        #expect(fixture.model.state == .idle)
        fixture.model.isOtherCaptureActive = { false }
        await fixture.setup()
        fixture.model.selectedID = "window"
        fixture.model.show(format: .gif)
        #expect(fixture.model.selectedID == "window")
        #expect(fixture.model.options.format == .mp4)
        #expect(fixture.presentations == 2)
        await fixture.clean()
    }

    @Test func `records pauses previews trims and saves`() async throws {
        let fixture = Fixture()
        await fixture.recording()
        #expect(fixture.model.state == .recording)
        fixture.model.start()
        #expect(fixture.engine.starts == 1)
        fixture.model.togglePause()
        #expect(fixture.model.state == .paused)
        fixture.model.togglePause()
        #expect(fixture.engine.pauses == [true, false])
        fixture.model.stop()
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        #expect(fixture.engine.stops == 1)
        #expect(fixture.model.state == .preview)
        #expect(fixture.model.duration > 1)
        #expect(fixture.model.playback.isLoaded)
        fixture.model.seek(0.2)
        fixture.model.trimStart = 0.2
        fixture.model.trimEnd = 0.8
        fixture.model.export()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .completed)
        let url = try #require(fixture.model.savedURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(fixture.model.sourceURL == nil)
        await fixture.clean()
    }

    @Test func `export failure and invalid trim keep recoverable source`() async throws {
        let fixture = Fixture(exportFails: true)
        await fixture.recording()
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        let source = try #require(fixture.model.sourceURL)
        fixture.model.trimStart = 2
        fixture.model.export()
        #expect(fixture.model.state == .preview)
        #expect(fixture.model.error != nil)
        fixture.model.trimStart = 0
        fixture.model.export()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .preview)
        #expect(fixture.model.error != nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
        await fixture.clean()
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func `cancellation during start drains the late start`() async {
        let fixture = Fixture()
        await fixture.setup()
        fixture.engine.blocksStart = true
        fixture.model.options.countdown = 0
        fixture.model.start()
        while fixture.engine.startGate == nil {
            await Task.yield()
        }
        fixture.model.cancel()
        fixture.engine.startGate?.resume()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .idle)
        #expect(fixture.engine.cancellations >= 1)
        #expect(fixture.engine.stops == 0)
        await fixture.clean()
    }

    @Test func `permission and startup failures return to setup`() async {
        let denied = Fixture(authorize: { _ in throw ScreenRecordingFailure.cameraPermission })
        await denied.setup()
        denied.model.start()
        await denied.model.pendingTask?.value
        #expect(denied.model.state == .setup)
        #expect(denied.engine.starts == 0)
        #expect(denied.model.error != nil)
        await denied.clean()
        let failed = Fixture()
        failed.engine.startError = ScreenRecordingFailure.encoding
        await failed.recording()
        #expect(failed.model.state == .setup)
        #expect(failed.model.error != nil)
        #expect(failed.engine.cancellations == 1)
        await failed.clean()
    }

    @Test func `interruption finishes partial recording and quit keeps recovery`() async throws {
        let fixture = Fixture()
        await fixture.recording()
        fixture.engine.onError?(ScreenRecordingFailure.interrupted)
        await fixture.model.pendingTask?.value
        #expect(fixture.model.state == .preview)
        #expect(fixture.model.error != nil)
        let url = try #require(fixture.model.sourceURL)
        await fixture.model.prepareForTermination()
        #expect(FileManager.default.fileExists(atPath: url.path))
        await fixture.clean()
    }

    @Test func `time labels and all error descriptions are localized`() {
        #expect(ScreenRecordingCoordinator.timeLabel(65) == "01:05")
        #expect(ScreenRecordingCoordinator.timeLabel(-1) == "00:00")
        #expect(ScreenRecordingCoordinator.timeLabel(.nan) == "00:00")
        for failure in [ScreenRecordingFailure.permission, .microphonePermission, .cameraPermission,
                        .unavailable, .noFrames, .encoding, .invalidRange, .interrupted] {
            #expect(failure.errorDescription != "recording.error." + failure.rawValue)
        }
    }
}
