@testable import Typeflux
import Combine
import XCTest

final class AppStateStoreTests: XCTestCase {
    @MainActor
    func testRepeatedStatusDoesNotPublishAndChangedFailureStillPublishes() {
        let store = AppStateStore()
        var values: [AppStatus] = []
        let subscription = store.$status.sink { values.append($0) }
        defer { subscription.cancel() }
        for _ in 0..<20 { store.setStatus(.idle) }
        store.setStatus(.recording)
        store.setStatus(.recording)
        store.setStatus(.failed(message: "first"))
        store.setStatus(.failed(message: "first"))
        store.setStatus(.failed(message: "second"))
        XCTAssertEqual(values, [.idle, .recording, .failed(message: "first"), .failed(message: "second")])
    }

    @MainActor
    func testBackgroundStatusesAreComparedAfterDeliveryToMainQueue() async {
        let store = AppStateStore()
        var values: [AppStatus] = []
        let subscription = store.$status.sink { values.append($0) }
        defer { subscription.cancel() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for _ in 0..<20 { store.setStatus(.recording) }
                store.setStatus(.idle)
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        XCTAssertEqual(values, [.idle, .recording, .idle])
    }

    func testInitialStatusIsIdle() {
        let store = AppStateStore()
        XCTAssertEqual(store.status, .idle)
    }

    func testSetStatusOnMainThread() {
        let store = AppStateStore()
        store.setStatus(.recording)
        XCTAssertEqual(store.status, .recording)
    }

    func testSetStatusToProcessing() {
        let store = AppStateStore()
        store.setStatus(.processing)
        XCTAssertEqual(store.status, .processing)
    }

    func testSetStatusToFailed() {
        let store = AppStateStore()
        store.setStatus(.failed(message: "Something went wrong"))
        if case let .failed(msg) = store.status {
            XCTAssertEqual(msg, "Something went wrong")
        } else {
            XCTFail("Expected .failed status")
        }
    }

    func testSetStatusFromBackgroundThread() {
        let store = AppStateStore()
        let expectation = XCTestExpectation(description: "Status updated from background")

        DispatchQueue.global().async {
            store.setStatus(.recording)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(store.status, .recording)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testStatusTransitions() {
        let store = AppStateStore()

        store.setStatus(.recording)
        XCTAssertEqual(store.status, .recording)

        store.setStatus(.processing)
        XCTAssertEqual(store.status, .processing)

        store.setStatus(.idle)
        XCTAssertEqual(store.status, .idle)
    }

    // MARK: - AppStatus Equatable

    func testAppStatusEquality() {
        XCTAssertEqual(AppStatus.idle, AppStatus.idle)
        XCTAssertEqual(AppStatus.recording, AppStatus.recording)
        XCTAssertEqual(AppStatus.processing, AppStatus.processing)
        XCTAssertEqual(AppStatus.failed(message: "x"), AppStatus.failed(message: "x"))
        XCTAssertNotEqual(AppStatus.failed(message: "x"), AppStatus.failed(message: "y"))
        XCTAssertNotEqual(AppStatus.idle, AppStatus.recording)
    }
}
