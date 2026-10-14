import AppKit
import AVFoundation
import Testing
@testable import Typeflux

@Suite("Recording user controls", .exclusiveUIState)
@MainActor
struct ScreenRecordingPresentationTests {
    @Test func `source modes never record an unintended display`() async {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        #expect(fixture.model.canStart)
        fixture.model.selectSourceKind(.window)
        #expect(fixture.model.selectedID.isEmpty)
        fixture.model.select(fixture.model.visibleSources[0])
        #expect(fixture.model.selectedID == "window")
        #expect(fixture.model.visibleSources.map(\.id) == ["window"])
        fixture.model.selectSourceKind(.region)
        #expect(!fixture.model.canStart)
        fixture.model.reloadChoices()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.sourceKind == .region)
        #expect(fixture.model.selectedID.isEmpty)
        #expect(!fixture.model.canStart)
        fixture.model.selectRegion()
        await fixture.model.pendingTask?.value
        fixture.overlay.event?(.committed)
        #expect(fixture.model.canStart)
        #expect(fixture.model.sourceSummary.contains("100 × 80"))
        await fixture.clean()
    }

    @Test func `trim endpoints stay ordered and export validates before saving`() async {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        #expect(fixture.model.canExport)
        fixture.model.setTrimStart(100)
        #expect(fixture.model.trimStart < fixture.model.trimEnd)
        fixture.model.setTrimEnd(-5)
        #expect(fixture.model.trimEnd > fixture.model.trimStart)
        fixture.model.setTrimStart(.nan)
        #expect(fixture.model.trimIsValid)
        fixture.model.resetTrim()
        #expect(fixture.model.trimStart == 0)
        #expect(fixture.model.trimEnd == fixture.model.duration)
        fixture.model.trimEnd = 100
        #expect(!fixture.model.canExport)
        fixture.model.resetTrim()
        #expect(fixture.model.destinationDirectory.lastPathComponent == "saved")
        await fixture.clean()
    }

    @Test(arguments: [ScreenRecordingFailure.cameraPermission, .microphonePermission, .unavailable])
    func `only permission failures offer the matching settings pane`(failure: ScreenRecordingFailure) async {
        let fixture = ScreenRecordingCoordinatorTests.Fixture(authorize: { _ in throw failure })
        await fixture.recording()
        #expect(fixture.model.state == .setup)
        if failure == .unavailable {
            #expect(fixture.model.permissionFailure == nil)
            #expect(fixture.model.devicePermissionURL == nil)
        } else {
            #expect(fixture.model.permissionFailure == failure)
            let suffix = failure == .cameraPermission ? "Privacy_Camera" : "Privacy_Microphone"
            #expect(fixture.model.devicePermissionURL?.absoluteString.hasSuffix(suffix) == true)
            #expect(fixture.model.permissionActionTitle != L("recording.permissions"))
        }
        await fixture.clean()
    }

    @Test func `trimming previews the selected time instead of an earlier keyframe`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop()
        await fixture.model.pendingTask?.value
        let player = try #require(fixture.model.player)
        fixture.model.setTrimStart(0.4)
        for _ in 0 ..< 100 {
            if abs(player.currentTime().seconds - 0.4) < 0.01 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(player.currentTime().seconds - 0.4) < 0.01)
        #expect(player.rate == 0)
        await fixture.clean()
    }

    @Test func `sound summary and recovery names use user language`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        #expect(fixture.model.audioSummary == L("recording.silent"))
        fixture.model.options.systemAudio = true
        fixture.model.options.microphone = true
        #expect(fixture.model.audioSummary.contains(L("recording.microphone")))
        fixture.model.options.format = .gif
        #expect(fixture.model.audioSummary == L("recording.silent"))
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let source = fixture.root.appendingPathComponent("source.mov")
        try Data().write(to: source)
        #expect(!ScreenRecordingCoordinator.recoveryTitle(source).contains(fixture.root.lastPathComponent))
        #expect(ScreenRecordingCoordinator
            .recoveryTitle(fixture.root.appendingPathComponent("missing")) == L("recording.recover"))
        await fixture.clean()
    }
}
