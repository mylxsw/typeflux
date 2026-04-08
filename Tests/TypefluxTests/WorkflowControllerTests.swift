@testable import Typeflux
import XCTest

final class WorkflowControllerTests: XCTestCase {
    func testWaitForRecordingStartCueSleepsAfterSuccessfulPlayback() async {
        let recorder = await MainActor.run { MainActorEventRecorder() }

        await WorkflowController.waitForRecordingStartCueIfNeeded(
            leadIn: .milliseconds(60),
            playCue: { @MainActor in
                recorder.record(event: "play")
                return true
            },
            sleep: { duration in
                await MainActor.run {
                    recorder.record(event: "sleep")
                    recorder.record(duration: duration)
                }
            },
        )

        let snapshot = await MainActor.run { recorder.snapshot() }
        XCTAssertEqual(snapshot.events, ["play", "sleep"])
        XCTAssertEqual(snapshot.duration, .milliseconds(60))
    }

    func testWaitForRecordingStartCueSkipsSleepWhenPlaybackDoesNotStart() async {
        let recorder = await MainActor.run { MainActorEventRecorder() }

        await WorkflowController.waitForRecordingStartCueIfNeeded(
            leadIn: .milliseconds(60),
            playCue: { @MainActor in
                recorder.record(event: "play")
                return false
            },
            sleep: { duration in
                await MainActor.run {
                    recorder.record(event: "sleep")
                    recorder.record(duration: duration)
                }
            },
        )

        let snapshot = await MainActor.run { recorder.snapshot() }
        XCTAssertEqual(snapshot.events, ["play"])
        XCTAssertNil(snapshot.duration)
    }
}

@MainActor
private final class MainActorEventRecorder {
    private var events: [String] = []
    private var duration: Duration?

    func record(event: String) {
        events.append(event)
    }

    func record(duration: Duration) {
        self.duration = duration
    }

    func snapshot() -> (events: [String], duration: Duration?) {
        (events, duration)
    }
}
