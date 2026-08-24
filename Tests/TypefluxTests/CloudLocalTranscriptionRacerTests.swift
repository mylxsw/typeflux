@testable import Typeflux
import XCTest

final class CloudLocalTranscriptionRacerTests: XCTestCase {
    func testDiagnosticsPreserveCachedLocalCompletionAndCancelCloudAtDeadline() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var builder = CloudLocalTranscriptionRacer.DiagnosticsBuilder(
            startedAt: startedAt,
            priorityWindowMilliseconds: 3_000
        )
        let localCompletion = CloudLocalTranscriptionRacer.TimedEvent(
            event: .completed(.local, .success("local")),
            elapsedMilliseconds: 640,
            occurredAt: startedAt.addingTimeInterval(0.64)
        )
        let deadline = CloudLocalTranscriptionRacer.TimedEvent(
            event: .priorityWindowExpired,
            elapsedMilliseconds: 3_000,
            occurredAt: startedAt.addingTimeInterval(3)
        )

        builder.receive(localCompletion)
        builder.receive(deadline)
        let diagnostics = builder.finalize(
            selectedSource: .local,
            selectionReason: .localAtPriorityDeadline,
            decision: deadline
        )

        XCTAssertEqual(diagnostics.selectedSource, .local)
        XCTAssertEqual(diagnostics.selectionReason, .localAtPriorityDeadline)
        XCTAssertTrue(diagnostics.cloudPriorityWindowExceeded)
        XCTAssertEqual(diagnostics.decisionDurationMilliseconds, 3_000)
        XCTAssertEqual(diagnostics.localAttempt.outcome, .succeeded)
        XCTAssertEqual(diagnostics.localAttempt.durationMilliseconds, 640)
        XCTAssertEqual(diagnostics.localAttempt.completedAt, localCompletion.occurredAt)
        XCTAssertEqual(diagnostics.cloudAttempt.outcome, .cancelled)
        XCTAssertEqual(diagnostics.cloudAttempt.durationMilliseconds, 3_000)
        XCTAssertNil(diagnostics.cloudAttempt.completedAt)
    }

    func testDiagnosticsCaptureFailureMetadataBeforeLocalFallbackWins() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        var builder = CloudLocalTranscriptionRacer.DiagnosticsBuilder(
            startedAt: startedAt,
            priorityWindowMilliseconds: 3_000
        )
        let cloudFailure = CloudLocalTranscriptionRacer.TimedEvent(
            event: .completed(.cloud, .failure(Self.error("cloud"))),
            elapsedMilliseconds: 220,
            occurredAt: startedAt.addingTimeInterval(0.22)
        )
        let localCompletion = CloudLocalTranscriptionRacer.TimedEvent(
            event: .completed(.local, .success("local")),
            elapsedMilliseconds: 780,
            occurredAt: startedAt.addingTimeInterval(0.78)
        )

        builder.receive(cloudFailure)
        builder.receive(localCompletion)
        let diagnostics = builder.finalize(
            selectedSource: .local,
            selectionReason: .localAfterCloudFailure,
            decision: localCompletion
        )

        XCTAssertFalse(diagnostics.cloudPriorityWindowExceeded)
        XCTAssertEqual(diagnostics.cloudAttempt.outcome, .failed)
        XCTAssertEqual(diagnostics.cloudAttempt.durationMilliseconds, 220)
        XCTAssertEqual(diagnostics.cloudAttempt.errorDomain, "cloud")
        XCTAssertEqual(diagnostics.cloudAttempt.errorCode, 1)
        XCTAssertEqual(diagnostics.localAttempt.outcome, .succeeded)
        XCTAssertEqual(diagnostics.localAttempt.durationMilliseconds, 780)
    }

    func testRacePublishesDiagnosticsToRecorder() async throws {
        let recorder = ASRRaceDiagnosticsRecorder()
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 60).race(
            cloud: { "cloud" },
            local: {
                try await Task.sleep(for: .seconds(60))
                return "local"
            },
            diagnosticsRecorder: recorder
        )

        let diagnostics = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(result.source, .cloud)
        XCTAssertEqual(diagnostics.selectedSource, .cloud)
        XCTAssertEqual(diagnostics.selectionReason, .cloudWithinPriorityWindow)
        XCTAssertEqual(diagnostics.cloudAttempt.outcome, .succeeded)
        XCTAssertEqual(diagnostics.localAttempt.outcome, .cancelled)
        XCTAssertFalse(diagnostics.cloudPriorityWindowExceeded)
    }

    func testCloudWinsWithinPriorityWindowEvenWhenLocalFinishesFirst() throws {
        var resolver = CloudLocalTranscriptionRacer.Resolver()

        XCTAssertNil(try resolver.receive(.completed(.local, .success("local"))))
        XCTAssertEqual(
            try resolver.receive(.completed(.cloud, .success("cloud"))),
            CloudLocalTranscriptionRaceResult(text: "cloud", source: .cloud)
        )
    }

    func testCachedLocalWinsWhenPriorityWindowExpires() throws {
        var resolver = CloudLocalTranscriptionRacer.Resolver()

        XCTAssertNil(try resolver.receive(.completed(.local, .success("local"))))
        XCTAssertEqual(
            try resolver.receive(.priorityWindowExpired),
            CloudLocalTranscriptionRaceResult(text: "local", source: .local)
        )
    }

    func testCloudCompletionWinsAfterPriorityWindowWhenNeitherWasReady() throws {
        var resolver = CloudLocalTranscriptionRacer.Resolver()

        XCTAssertNil(try resolver.receive(.priorityWindowExpired))
        XCTAssertEqual(
            try resolver.receive(.completed(.cloud, .success("cloud"))),
            CloudLocalTranscriptionRaceResult(text: "cloud", source: .cloud)
        )
    }

    func testLocalCompletionWinsAfterPriorityWindowWhenNeitherWasReady() throws {
        var resolver = CloudLocalTranscriptionRacer.Resolver()

        XCTAssertNil(try resolver.receive(.priorityWindowExpired))
        XCTAssertEqual(
            try resolver.receive(.completed(.local, .success("local"))),
            CloudLocalTranscriptionRaceResult(text: "local", source: .local)
        )
    }

    func testCloudFailureImmediatelyReleasesCachedLocalResult() throws {
        var resolver = CloudLocalTranscriptionRacer.Resolver()

        XCTAssertNil(try resolver.receive(.completed(.local, .success("local"))))
        XCTAssertEqual(
            try resolver.receive(.completed(.cloud, .failure(Self.error("cloud")))),
            CloudLocalTranscriptionRaceResult(text: "local", source: .local)
        )
    }

    func testLocalFailureKeepsWaitingForCloudBeyondPriorityWindow() throws {
        var resolver = CloudLocalTranscriptionRacer.Resolver()

        XCTAssertNil(try resolver.receive(.completed(.local, .failure(Self.error("local")))))
        XCTAssertNil(try resolver.receive(.priorityWindowExpired))
        XCTAssertEqual(
            try resolver.receive(.completed(.cloud, .success("cloud"))),
            CloudLocalTranscriptionRaceResult(text: "cloud", source: .cloud)
        )
    }

    func testEmptyCloudResultFallsBackToCachedLocalResult() async throws {
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 60).race(
            cloud: { "  \n" },
            local: { "local" }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "local", source: .local))
    }

    func testBothFailuresArePreservedForFallbackHandling() async {
        do {
            _ = try await CloudLocalTranscriptionRacer(priorityWindow: 60).race(
                cloud: { throw Self.error("cloud") },
                local: { throw Self.error("local") }
            )
            XCTFail("Expected both transcription operations to fail")
        } catch let error as CloudLocalTranscriptionRaceError {
            XCTAssertEqual((error.cloudError as NSError?)?.domain, "cloud")
            XCTAssertEqual((error.localError as NSError?)?.domain, "local")
            XCTAssertEqual(
                error.errorDescription,
                "Cloud and local transcription failed (cloud: The operation couldn’t be completed. (cloud error 1.); "
                    + "local: The operation couldn’t be completed. (local error 1.))."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationStopsWaitingForRaceResults() async {
        let cloud = SuspendedTranscriptionOperation()
        let local = SuspendedTranscriptionOperation()
        let task = Task {
            try await CloudLocalTranscriptionRacer(priorityWindow: 60).race(
                cloud: { try await cloud.run() },
                local: { try await local.run() }
            )
        }

        await cloud.waitUntilStarted()
        await local.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func error(_ domain: String) -> NSError {
        NSError(domain: domain, code: 1)
    }
}

private actor SuspendedTranscriptionOperation {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async throws -> String {
        hasStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(for: .seconds(60))
        return "unused"
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}
