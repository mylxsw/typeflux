@testable import Typeflux
import XCTest

final class WorkflowOverlayPresentationPolicyTests: XCTestCase {
    @MainActor
    func testNativeCallbackTargetDoesNotKeepDestroyedOverlayAlive() {
        let suite = "OverlayCallbackTargetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var controller: OverlayController? = OverlayController(
            appState: AppStateStore(), settingsStore: SettingsStore(defaults: defaults)
        )
        let target = OverlayCallbackTarget(controller!)
        XCTAssertNotNil(target.controller)
        controller = nil
        XCTAssertNil(target.controller)
    }

    func testPickerAndProcessingPreserveSourceKeyboardFocus() {
        let presentations: [OverlayViewModel.Presentation] = [
            .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview,
            .processing, .processingPreview, .transcriptPreview, .notice, .failure, .personaPicker
        ]
        for presentation in presentations {
            XCTAssertFalse(presentation.acceptsKeyboardFocus)
        }
        XCTAssertTrue(OverlayViewModel.Presentation.resultDialog.acceptsKeyboardFocus)
    }

    func testShowProcessingAfterRecordingAlwaysLeavesRecordingState() {
        XCTAssertTrue(WorkflowOverlayPresentationPolicy.shouldShowProcessingAfterRecording())
    }

    func testShouldPresentResultDialogForFocusedReadOnlySelection() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = "Selected text"
        snapshot.isFocusedTarget = true
        snapshot.isEditable = false

        XCTAssertTrue(WorkflowOverlayPresentationPolicy.shouldPresentResultDialog(for: snapshot))
    }

    func testShouldNotPresentResultDialogForReplaceableSelection() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = "Editable text"
        snapshot.isFocusedTarget = true
        snapshot.isEditable = true

        XCTAssertFalse(WorkflowOverlayPresentationPolicy.shouldPresentResultDialog(for: snapshot))
    }

    func testShouldNotShowLLMStreamingPreviewAfterTranscription() {
        XCTAssertFalse(WorkflowOverlayPresentationPolicy.shouldShowLLMStreamingPreviewAfterTranscription())
    }

    func testShouldNotShowLLMStreamingPreviewForPersonaSelectionApplication() {
        XCTAssertFalse(WorkflowOverlayPresentationPolicy.shouldShowLLMStreamingPreviewForPersonaSelectionApplication())
    }
}
