import AppKit
import Testing
@testable import Typeflux

@Suite("Independent recording sessions", .exclusiveUIState)
@MainActor
struct ScreenRecordingSessionControllerTests {
    @MainActor
    final class Fixture {
        let suite = UUID().uuidString
        let settings: SettingsStore
        var recordings: [ScreenRecordingCoordinatorTests.Fixture] = []
        lazy var controller = ScreenRecordingSessionController(settings: settings, makeWindow: { [settings] in
            ScreenRecordingWindowController(settings: settings, preview: ScreenRecordingVisualTests.Devices())
        }) { [unowned self] in
            let recording = ScreenRecordingCoordinatorTests.Fixture()
            recordings.append(recording)
            return recording.model
        }

        init() {
            _ = NSApplication.shared
            settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        }

        func record() async -> ScreenRecordingSessionController.Session {
            controller.show()
            let session = controller.sessions.last!
            await session.model.pendingTask?.value
            session.model.selectSourceKind(.display)
            session.model.options.countdown = 0
            session.model.start()
            await session.model.pendingTask?.value
            session.model.stop()
            await session.model.pendingTask?.value
            return session
        }

        func clean() async {
            let windows = controller.sessions.map(\.window)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            for recording in recordings {
                await recording.clean()
            }
            for window in windows {
                window.hide()
                await window.deviceTask?.value
            }
        }
    }

    @Test func `unsaved results allow screenshots and another recording with independent edits and disposal`(
    ) async throws {
        let fixture = Fixture()
        let first = await fixture.record()
        let source = try #require(first.model.sourceURL)
        let firstWindow = try #require(first.window.window)
        first.model.fileName = "First recording"
        first.model.setTrimStart(0.2)
        #expect(!fixture.controller.isCaptureActive)
        #expect(fixture.controller.isBusy)
        #expect(firstWindow.identifier == ScreenRecordingWindowController.previewIdentifier)
        #expect(!ScreenshotCaptureWindowPolicy.excludes(firstWindow))

        let second = await fixture.record()
        let secondWindow = try #require(second.window.window)
        let secondSource = try #require(second.model.sourceURL)
        #expect(firstWindow !== secondWindow)
        #expect(firstWindow.isVisible && secondWindow.isVisible)
        #expect(first.model.fileName == "First recording")
        #expect(first.model.trimStart == 0.2)
        #expect(second.model.trimStart == 0)
        #expect(source != secondSource)
        #expect(fixture.controller.sessions.count == 2)
        #expect(!fixture.controller.isCaptureActive)

        first.model.cancel()
        await first.model.pendingTask?.value
        #expect(fixture.controller.sessions.count == 1)
        #expect(!firstWindow.isVisible)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(secondWindow.isVisible && second.model.state == .preview)
        #expect(FileManager.default.fileExists(atPath: secondSource.path))
        await fixture.clean()
        #expect(fixture.controller.sessions.isEmpty)
    }

    @Test func `export does not block capture and saving closes only its own result`() async throws {
        let fixture = Fixture()
        let first = await fixture.record()
        let second = await fixture.record()
        let secondSource = try #require(second.model.sourceURL)
        first.model.export()
        #expect(first.model.state == .exporting)
        #expect(!fixture.controller.isCaptureActive)
        fixture.controller.show(format: .gif)
        let third = try #require(fixture.controller.sessions.last)
        #expect(third.model !== first.model && third.model !== second.model)
        #expect(third.model.options.format == .gif)
        #expect(third.model.state == .setup)
        await first.model.pendingTask?.value
        try await SettingsBehaviorTestSupport.wait { first.model.state == .idle }
        #expect(first.model.state == .idle)
        #expect(fixture.controller.sessions.count == 2)
        #expect(second.model.state == .preview && second.window.window?.isVisible == true)
        #expect(third.model.state == .setup && third.window.window?.isVisible == true)
        #expect(FileManager.default.fileExists(atPath: secondSource.path))
        #expect(try FileManager.default.fileExists(atPath: #require(first.model.savedURL).path))
        await fixture.clean()
    }

    @Test func `only a live capture blocks new sessions and screenshot activity prevents setup`() async {
        let fixture = Fixture()
        fixture.controller.isOtherCaptureActive = { true }
        fixture.controller.show()
        #expect(fixture.controller.sessions.isEmpty)
        fixture.controller.isOtherCaptureActive = { false }
        fixture.controller.show(format: .gif)
        let model = fixture.controller.sessions[0].model
        await model.pendingTask?.value
        #expect(fixture.controller.isCaptureActive)
        fixture.controller.show(format: .mp4)
        #expect(fixture.controller.sessions.count == 1)
        #expect(model.options.format == .gif)
        model.selectSourceKind(.display)
        model.options.countdown = 0
        model.start()
        await model.pendingTask?.value
        #expect(model.state == .recording)
        model.togglePause()
        fixture.controller.show()
        #expect(fixture.controller.sessions.count == 1)
        #expect(fixture.controller.isCaptureActive)
        await fixture.clean()
        #expect(!fixture.controller.isBusy && !fixture.controller.isCaptureActive)
    }

    @Test func `discard releases the session and its editor`() async throws {
        let fixture = Fixture()
        weak var model: ScreenRecordingCoordinator?
        weak var presenter: ScreenRecordingWindowController?
        do {
            let result = await fixture.record()
            model = result.model
            presenter = result.window
        }
        await fixture.clean()
        fixture.recordings.removeAll()
        try await SettingsBehaviorTestSupport.wait { model == nil && presenter == nil }
        #expect(fixture.controller.sessions.isEmpty)
    }

    @Test func `quit retains every unsaved source and drains current setup`() async throws {
        let fixture = Fixture()
        let first = await fixture.record()
        let second = await fixture.record()
        let sources = try [#require(first.model.sourceURL), #require(second.model.sourceURL)]
        fixture.controller.show()
        await fixture.controller.prepareForTermination()
        #expect(fixture.controller.sessions.count == 2)
        #expect(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(first.model.state == .preview && second.model.state == .preview)
        await fixture.clean()
    }

    @Test func `recovering a result opens it independently without duplicating an open editor`() async throws {
        let fixture = Fixture()
        let original = ScreenRecordingCoordinatorTests.Fixture()
        await original.recording()
        original.model.stop()
        await original.model.pendingTask?.value
        let source = try #require(original.model.sourceURL)
        let first = await fixture.record()
        fixture.controller.recover(source)
        let recovered = try #require(fixture.controller.sessions.last)
        fixture.controller.recover(source)
        #expect(fixture.controller.sessions.count == 2)
        await recovered.model.pendingTask?.value
        #expect(recovered.model.state == .preview)
        #expect(recovered.model.sourceURL == source)
        #expect(first.window.window?.isVisible == true)
        fixture.controller.recover(source)
        #expect(fixture.controller.sessions.count == 2)
        #expect(!fixture.controller.isCaptureActive)
        fixture.controller.show()
        #expect(fixture.controller.sessions.count == 3)
        await fixture.clean()
        await original.clean()
    }
}
