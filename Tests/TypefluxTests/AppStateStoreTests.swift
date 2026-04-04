import XCTest
@testable import Typeflux

final class AppStateStoreTests: XCTestCase {

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
        if case .failed(let msg) = store.status {
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
