@testable import Typeflux
import XCTest

extension WorkflowControllerProcessingTests {
    @MainActor
    func testSemanticIndexingPriorityFollowsRecordingAndProcessing() async {
        let controller = makeWorkflowController()
        var events: [Bool] = []
        controller.onForegroundActivityChanged = { events.append($0) }
        controller.isRecording = true
        let processing = Task<Void, Never> {}
        controller.processingTask = processing
        controller.isRecording = false
        controller.processingTask = nil
        await processing.value
        XCTAssertEqual(events, [true, true, true, false], "indexing may resume only when both activities have ended")
        controller.onForegroundActivityChanged = nil
    }
}
