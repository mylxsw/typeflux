import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized)
struct OverlayTransitionTests {
    @Test @MainActor
    func captionsExpandAndCollapseAroundTheSameBottomAnchor() async throws {
        let (controller, window) = try makeRecording()
        defer { controller.dismissImmediately() }
        let compactFrame = window.frame

        controller.updateRecordingPreviewText("A short caption for checking the recording capsule.")
        let expandedFrame = window.frame
        #expect(expandedFrame.width > compactFrame.width)
        #expect(expandedFrame.height > compactFrame.height)
        #expect(expandedFrame.minY == compactFrame.minY)
        #expect(expandedFrame.midX == compactFrame.midX)
        try await settle()

        controller.updateRecordingPreviewText("")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(window.frame == expandedFrame)
        }
        // Further empty updates must not restart the shrink deadline.
        try await Task.sleep(for: .milliseconds(200))
        controller.updateRecordingPreviewText("   ")
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.frame == compactFrame)
        #expect(controller.recordingPresentationForTesting == .recordingHold)
    }

    @Test @MainActor
    func reopeningCaptionsCancelsThePendingWindowShrink() async throws {
        let (controller, window) = try makeRecording()
        defer { controller.dismissImmediately() }
        controller.updateRecordingPreviewText("First caption")
        try await settle()
        let expandedFrame = window.frame
        controller.updateRecordingPreviewText("")
        try await Task.sleep(for: .milliseconds(70))
        controller.updateRecordingPreviewText("A new caption arrives while the capsule is shrinking.")
        try await settle()

        #expect(window.isVisible)
        #expect(window.frame == expandedFrame)
        #expect(controller.recordingPresentationForTesting == .recordingHoldPreview)
    }

    @Test @MainActor
    func lateCaptionsCannotReverseTheTransitionToProcessing() async throws {
        let (controller, window) = try makeRecording()
        defer { controller.dismissImmediately() }
        controller.updateRecordingPreviewText("Caption before processing")
        try await settle()
        controller.showProcessing()
        controller.transitionToLLMPhase()
        controller.updateRecordingPreviewText("Late caption after recording has finished")
        try await settle()

        #expect(window.isVisible)
        #expect(controller.recordingPresentationForTesting == .processing)
        #expect(controller.processingProgressForTesting >= 0.7)
    }

    @Test @MainActor
    func aNewRecordingCancelsThePreviousProcessingTransition() async throws {
        let (controller, window) = try makeRecording()
        defer { controller.dismissImmediately() }
        let compactFrame = window.frame
        controller.updateRecordingPreviewText("Caption before processing")
        controller.showProcessing()
        try await Task.sleep(for: .milliseconds(70))
        controller.show()
        try await settle()

        #expect(window.isVisible)
        #expect(window.frame == compactFrame)
        #expect(controller.recordingPresentationForTesting == .recordingHold)
    }

    @Test @MainActor
    func reopeningDuringDismissalKeepsTheNewRecordingVisible() async throws {
        let (controller, window) = try makeRecording()
        defer { controller.dismissImmediately() }
        try await settle()
        controller.dismiss(after: 0)
        try await Task.sleep(for: .milliseconds(70))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(window.isVisible)
        }
        controller.showLockedRecording()
        try await settle()

        #expect(window.isVisible)
        #expect(controller.recordingPresentationForTesting == .recordingLocked)
        controller.dismissImmediately()
        #expect(!window.isVisible)
        try await settle()
        #expect(!window.isVisible)
    }

    @Test @MainActor
    func dismissalFinishesAndLateCaptionsCannotReopenTheWindow() async throws {
        let (controller, window) = try makeRecording()
        defer { controller.dismissImmediately() }
        try await settle()
        controller.dismiss(after: 0)
        try await settle()
        #expect(!window.isVisible)
        controller.updateRecordingPreviewText("Late caption")
        #expect(!window.isVisible)

        controller.showProcessing()
        try await settle()
        controller.dismiss(after: 0)
        try await settle()
        controller.updateStreamingText("Late processing caption")
        #expect(!window.isVisible)
    }

    @MainActor
    private func makeRecording() throws -> (OverlayController, NSWindow) {
        let application = NSApplication.shared
        let previousWindows = Set(application.windows.map(\.windowNumber))
        let controller = OverlayController(appState: AppStateStore())
        controller.show()
        let window = try #require(application.windows.first {
            !previousWindows.contains($0.windowNumber) && $0.isVisible
        })
        return (controller, window)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(420))
    }
}
