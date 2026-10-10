import AppKit
import Testing
@testable import Typeflux

/// The "attach screenshot" path on top of the shared capture and permission services.
@Suite("Ask screenshot capture", .exclusiveUIState)
@MainActor
struct AskScreenshotCaptureTests {
    private struct SystemFailure: Error {}

    private func snapshot(displayID: CGDirectDisplayID = 3, width: Int = 160, height: Int = 90) -> ScreenSnapshot {
        ScreenSnapshot(displays: [.init(id: displayID, frame: CGRect(x: 0, y: 0, width: width, height: height),
                                        scale: 1, image: ScreenCaptureTestSupport.image(width: width, height: height))],
                       windows: [])
    }

    @Test func requestsOneDownscaledDisplayWithoutWindows() async throws {
        let capturer = FakeScreenCapturer(.success(snapshot()))
        let shot = try await AskContextCapture.screenshot(
            displayId: 3, permission: FakeScreenCapturePermission(granted: true), capturer: capturer
        )
        #expect(capturer.requests == [ScreenCaptureRequest(
            displays: .preferred(3), resolution: .fitting(maxDimension: 1600), includesWindows: false
        )])
        #expect(shot.displayId == 3 && shot.width == 160 && shot.height == 90)
        #expect(shot.dataURL.hasPrefix("data:image/jpeg;base64,"))
        let encoded = try #require(Data(base64Encoded: String(shot.dataURL.dropFirst("data:image/jpeg;base64,".count))))
        #expect(NSBitmapImageRep(data: encoded) != nil)
    }

    @Test(arguments: [true, false])
    func missingAccessAsksOnlyWhenAllowed(_ requestAccessIfNeeded: Bool) async {
        let permission = FakeScreenCapturePermission()
        let capturer = FakeScreenCapturer(.success(snapshot()))
        await #expect(throws: AskLocalError.self) {
            try await AskContextCapture.screenshot(requestAccessIfNeeded: requestAccessIfNeeded,
                                                   permission: permission, capturer: capturer)
        }
        #expect(permission.onceRequests == (requestAccessIfNeeded ? 1 : 0))
        #expect(permission.requests == 0)
        #expect(capturer.requests.isEmpty)
    }

    @Test(arguments: [(ScreenCaptureError.permissionDenied, "ask.capture.permission"),
                      (ScreenCaptureError.unavailable, "ask.capture.unavailable")])
    func captureErrorsKeepTheirMessages(_ error: ScreenCaptureError, _ key: String) async {
        let capturer = FakeScreenCapturer(.failure(error))
        do {
            _ = try await AskContextCapture.screenshot(permission: FakeScreenCapturePermission(granted: true),
                                                       capturer: capturer)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.localizedDescription == L(key))
        }
    }

    @Test func otherErrorsPassThroughAndEmptySnapshotsAreUnavailable() async {
        let permission = FakeScreenCapturePermission(granted: true)
        await #expect(throws: SystemFailure.self) {
            try await AskContextCapture.screenshot(permission: permission,
                                                   capturer: FakeScreenCapturer(.failure(SystemFailure())))
        }
        do {
            _ = try await AskContextCapture.screenshot(
                permission: permission,
                capturer: FakeScreenCapturer(.success(ScreenSnapshot(displays: [], windows: [])))
            )
            Issue.record("Expected a failure")
        } catch {
            #expect(error.localizedDescription == L("ask.capture.unavailable"))
        }
    }

    @Test func contextCaptureUsesTheInjectedServices() async {
        let permission = FakeScreenCapturePermission(granted: true)
        let capturer = FakeScreenCapturer(.success(snapshot()))
        let capture = AskContextCapture(injector: ContextTextInjector(), permission: permission, capturer: capturer,
                                        accessibilityTrusted: { false }, frontmostProcessID: { 42 })
        let context = await capture.capture(includeScreenshot: true, includeSelection: false)
        #expect(context.screenshot?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(capturer.requests.first?.resolution == .fitting(maxDimension: 1600))
        // The launcher's own capture never asks for access.
        #expect(permission.onceRequests == 0 && permission.requests == 0)
    }

    @Test func contextCapturePermissionActionsGoThroughTheService() {
        let permission = FakeScreenCapturePermission()
        let capture = AskContextCapture(injector: ContextTextInjector(), permission: permission,
                                        capturer: FakeScreenCapturer(.success(snapshot())),
                                        accessibilityTrusted: { false }, frontmostProcessID: { 42 })
        #expect(!capture.screenCaptureAllowed)
        #expect(!capture.requestScreenCapturePermission())
        #expect(permission.requests == 1)
        capture.openScreenCaptureSettings()
        #expect(permission.requests == 2 && permission.settingsOpened == 1)
        permission.grantsRequest = true
        #expect(capture.requestScreenCapturePermission() && capture.screenCaptureAllowed)
    }

    @Test func modelOpensSettingsThroughItsCapture() throws {
        let probe = ScreenshotPermissionProbe()
        let fixture = try AskTestFixture(captureOverride: probe.capture)
        defer { fixture.model.resetSession() }
        fixture.model.openScreenCaptureSettings()
        #expect(probe.permission.settingsOpened == 1 && probe.requests == 1)
    }

    @Test func screenObservationCapturesThroughTheService() async throws {
        let capturer = FakeScreenCapturer(.success(snapshot(displayID: 5)))
        let observation = AskScreenObservation(capturer: capturer,
                                               permission: FakeScreenCapturePermission(granted: true))
        let shot = try await observation.capture(5)
        #expect(shot.displayId == 5)
        #expect(capturer.requests.first?.displays == .preferred(5))
    }

    @Test func screenObservationAsksOnceWhenAccessIsMissing() async {
        let permission = FakeScreenCapturePermission()
        let observation = AskScreenObservation(capturer: FakeScreenCapturer(.success(snapshot())),
                                               permission: permission)
        await #expect(throws: AskLocalError.self) { try await observation.capture(1) }
        #expect(permission.onceRequests == 1)
    }

    @Test func agentSettingsRequestBeforeOpeningSettings() {
        let fake = FakeScreenCapturePermission()
        let permissions = AgentAutomationPermissions.system(screenCapture: fake)
        permissions.requestScreenRecording()
        #expect(fake.requests == 1 && fake.settingsOpened == 1)
        fake.granted = true
        permissions.requestScreenRecording()
        #expect(fake.requests == 1 && fake.settingsOpened == 1)
    }

    @Test func jpegEncodingKeepsTheAspectRatio() throws {
        let url = try #require(AskContextCapture.jpegDataURL(ScreenCaptureTestSupport.image(width: 20, height: 10)))
        let data = try #require(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))))
        // The bitmap follows the main screen's backing scale, so only the aspect ratio is fixed.
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == bitmap.pixelsHigh * 2 && bitmap.pixelsHigh >= 10)
    }
}
