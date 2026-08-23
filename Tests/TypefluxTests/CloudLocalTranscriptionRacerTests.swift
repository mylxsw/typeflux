@testable import Typeflux
import XCTest

final class CloudLocalTranscriptionRacerTests: XCTestCase {
    func testCloudWinsWithinPriorityWindowEvenWhenLocalFinishesFirst() async throws {
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 0.1).race(
            cloud: { try await Self.succeed("cloud", after: 0.02) },
            local: { try await Self.succeed("local", after: 0.005) }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "cloud", source: .cloud))
    }

    func testCachedLocalWinsWhenPriorityWindowExpires() async throws {
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 0.02).race(
            cloud: { try await Self.succeed("cloud", after: 0.2) },
            local: { try await Self.succeed("local", after: 0.005) }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "local", source: .local))
    }

    func testFirstCompletionWinsAfterPriorityWindowWhenNeitherWasReady() async throws {
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 0.01).race(
            cloud: { try await Self.succeed("cloud", after: 0.04) },
            local: { try await Self.succeed("local", after: 0.08) }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "cloud", source: .cloud))
    }

    func testLocalCompletionWinsAfterPriorityWindowWhenNeitherWasReady() async throws {
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 0.01).race(
            cloud: { try await Self.succeed("cloud", after: 0.08) },
            local: { try await Self.succeed("local", after: 0.04) }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "local", source: .local))
    }

    func testCloudFailureImmediatelyReleasesCachedLocalResult() async throws {
        let startedAt = Date()
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 0.2).race(
            cloud: { try await Self.fail("cloud", after: 0.02) },
            local: { try await Self.succeed("local", after: 0.005) }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "local", source: .local))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.15)
    }

    func testLocalFailureKeepsWaitingForCloudBeyondPriorityWindow() async throws {
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 0.01).race(
            cloud: { try await Self.succeed("cloud", after: 0.04) },
            local: { try await Self.fail("local", after: 0.005) }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "cloud", source: .cloud))
    }

    func testEmptyCloudResultFallsBackToCachedLocalResult() async throws {
        let result = try await CloudLocalTranscriptionRacer(priorityWindow: 0.2).race(
            cloud: { try await Self.succeed("  \n", after: 0.02) },
            local: { try await Self.succeed("local", after: 0.005) }
        )

        XCTAssertEqual(result, CloudLocalTranscriptionRaceResult(text: "local", source: .local))
    }

    func testBothFailuresArePreservedForFallbackHandling() async {
        do {
            _ = try await CloudLocalTranscriptionRacer(priorityWindow: 0.1).race(
                cloud: { try await Self.fail("cloud", after: 0.005) },
                local: { try await Self.fail("local", after: 0.01) }
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

    func testCancellationStopsWaitingForRaceResults() async throws {
        let task = Task {
            try await CloudLocalTranscriptionRacer(priorityWindow: 1).race(
                cloud: { try await Self.succeed("cloud", after: 1) },
                local: { try await Self.succeed("local", after: 1) }
            )
        }

        try await Task.sleep(nanoseconds: 10_000_000)
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

    private static func succeed(_ text: String, after delay: TimeInterval) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return text
    }

    private static func fail(_ domain: String, after delay: TimeInterval) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        throw NSError(domain: domain, code: 1)
    }
}
