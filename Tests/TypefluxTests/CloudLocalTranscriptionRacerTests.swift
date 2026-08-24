@testable import Typeflux
import XCTest

final class CloudLocalTranscriptionRacerTests: XCTestCase {
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
