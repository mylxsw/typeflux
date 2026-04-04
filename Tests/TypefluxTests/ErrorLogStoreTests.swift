import XCTest
@testable import Typeflux

final class ErrorLogStoreTests: XCTestCase {

    func testLogInsertsEntryAtFront() {
        let store = ErrorLogStore()
        let expectation = XCTestExpectation(description: "Entry inserted")

        store.log("first error")
        store.log("second error")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(store.entries.count, 2)
            XCTAssertEqual(store.entries.first?.message, "second error")
            XCTAssertEqual(store.entries.last?.message, "first error")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testClearRemovesAllEntries() {
        let store = ErrorLogStore()
        let expectation = XCTestExpectation(description: "Cleared")

        store.log("error 1")
        store.log("error 2")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            store.clear()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertTrue(store.entries.isEmpty)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testEntryHasDateAndMessage() {
        let store = ErrorLogStore()
        let expectation = XCTestExpectation(description: "Entry verified")

        let beforeDate = Date()
        store.log("test message")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let entry = store.entries.first
            XCTAssertNotNil(entry)
            XCTAssertEqual(entry?.message, "test message")
            XCTAssertGreaterThanOrEqual(entry?.date ?? Date.distantPast, beforeDate)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testEntryHasUniqueID() {
        let store = ErrorLogStore()
        let expectation = XCTestExpectation(description: "Unique IDs")

        store.log("a")
        store.log("b")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertNotEqual(store.entries[0].id, store.entries[1].id)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }
}
