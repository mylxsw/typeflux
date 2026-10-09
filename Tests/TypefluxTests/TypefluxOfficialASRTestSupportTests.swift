@testable import Typeflux
import XCTest

/// The ASR test fixtures report every way a wait can end instead of
/// returning as if the worker had arrived, and leave no task or listener
/// running when a test stops early.
final class TypefluxOfficialASRTestSupportTests: XCTestCase {
    // MARK: - Parking gate

    func testReleaseBeforeTheWorkerParksLetsItPassThrough() async throws {
        let gate = ParkingGate()
        await gate.release()
        let passed = expectation(description: "worker passed the gate")
        let worker = owned(releasing: [gate]) {
            await gate.park()
            passed.fulfill()
            return 1
        }

        await fulfillment(of: [passed], timeout: 5)
        let value = try await worker.value
        XCTAssertEqual(value, 1)
    }

    func testReleaseAfterTheWorkerParksLetsItContinue() async throws {
        let gate = ParkingGate()
        let worker = owned(releasing: [gate]) {
            await gate.park()
            return 2
        }

        try await gate.waitUntilParked(unlessFinished: worker)
        XCTAssertFalse(worker.isFinished)
        await gate.release()
        let value = try await worker.value
        XCTAssertEqual(value, 2)
    }

    func testWaitReportsAWorkerThatReturnedWithoutParking() async throws {
        let gate = ParkingGate()
        let worker = owned(releasing: [gate]) { 3 }

        await assertWait(on: gate, for: worker, failsWith: .workerFinished)
        let value = try await worker.value
        XCTAssertEqual(value, 3)
    }

    func testWaitReportsAWorkerThatFailedWithoutParking() async throws {
        let gate = ParkingGate()
        let worker = owned(releasing: [gate]) { () throws -> Int in
            throw URLError(.cannotConnectToHost)
        }

        await assertWait(on: gate, for: worker, failsWith: .workerFinished)
        do {
            _ = try await worker.value
            XCTFail("Expected the worker's error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
    }

    func testWaitTimesOutWhenNothingParks() async {
        let gate = ParkingGate()

        do {
            try await gate.waitUntilParked(timeout: .milliseconds(20))
            XCTFail("Expected the wait to time out")
        } catch {
            XCTAssertEqual(error as? GateWaitError, .timedOut)
        }
    }

    func testCancelledWaitStopsWaiting() async {
        let gate = ParkingGate()
        let waiter = owned(releasing: []) { () throws -> Int in
            try await gate.waitUntilParked(timeout: .seconds(60))
            return 0
        }

        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected the wait to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error \(error)")
        }
    }

    func testFailedWaitStillEndsAWorkerParkedElsewhere() async {
        let awaited = ParkingGate()
        let elsewhere = ParkingGate()
        let worker = OwnedWorker { () -> Int in
            await elsewhere.park()
            await awaited.park()
            return 4
        }

        await assertWait(on: awaited, for: worker, failsWith: .timedOut, timeout: .milliseconds(50))
        // `awaited` is released before the worker reaches it; the release is
        // kept, so stopping still ends the worker.
        await worker.stop(releasing: [awaited, elsewhere])
        XCTAssertTrue(worker.isFinished)
        let released = await awaited.isReleased
        XCTAssertTrue(released)
    }

    // MARK: - Gateway pair

    func testSecondGatewayFailingToStartStopsTheFirst() async throws {
        var started: [LocalASRGateway] = []

        do {
            _ = try await LocalASRGateway.startPair(.succeed("a"), .succeed("b")) { behavior in
                guard started.isEmpty else { throw URLError(.cannotConnectToHost) }
                let gateway = try await LocalASRGateway.start(behavior: behavior)
                started.append(gateway)
                return gateway
            }
            XCTFail("Expected the second gateway to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }

        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(started.allSatisfy(\.isStopped))
    }

    func testGatewayPairStartsBothGateways() async throws {
        let (first, second) = try await LocalASRGateway.startPair(.succeed("a"), .rejectConnection)
        defer {
            first.stop()
            second.stop()
        }

        XCTAssertFalse(first.isStopped)
        XCTAssertFalse(second.isStopped)
        XCTAssertNotEqual(first.baseURL, second.baseURL)
    }

    // MARK: - Helpers

    private func owned<Value: Sendable>(
        releasing gates: [ParkingGate],
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> OwnedWorker<Value> {
        let worker = OwnedWorker(operation)
        addTeardownBlock { await worker.stop(releasing: gates) }
        return worker
    }

    private func assertWait(
        on gate: ParkingGate,
        for worker: some FinishReporting,
        failsWith expected: GateWaitError,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await gate.waitUntilParked(unlessFinished: worker, timeout: timeout)
            XCTFail("Expected the wait to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GateWaitError, expected, file: file, line: line)
        }
    }
}
