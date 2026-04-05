import XCTest
@testable import Typeflux

final class WorkflowOverlayPresentationPolicyTests: XCTestCase {

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
}
