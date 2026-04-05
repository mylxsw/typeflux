@testable import Typeflux
import XCTest

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

// MARK: - Extended ErrorLogStore tests

extension ErrorLogStoreTests {
    func testLogEntriesHaveCorrectMessages() {
        let store = ErrorLogStore()
        let expectation = XCTestExpectation(description: "Entries with correct messages")

        store.log("message-a")
        store.log("message-b")
        store.log("message-c")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let messages = store.entries.map(\.message)
            XCTAssertTrue(messages.contains("message-a"))
            XCTAssertTrue(messages.contains("message-b"))
            XCTAssertTrue(messages.contains("message-c"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testLogEntriesHaveUniqueIDs() {
        let store = ErrorLogStore()
        let expectation = XCTestExpectation(description: "Unique IDs")

        store.log("error-1")
        store.log("error-2")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let ids = store.entries.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testLogEntriesHaveRecentTimestamps() {
        let store = ErrorLogStore()
        let before = Date()
        let expectation = XCTestExpectation(description: "Recent timestamps")

        store.log("timed error")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let after = Date()
            if let entry = store.entries.first(where: { $0.message == "timed error" }) {
                XCTAssertGreaterThanOrEqual(entry.date, before)
                XCTAssertLessThanOrEqual(entry.date, after)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testLogEnforcesMaxEntries() {
        let store = ErrorLogStore()
        let expectation = XCTestExpectation(description: "Max entries enforced")

        // Log 105 entries (max is 100)
        for i in 0 ..< 105 {
            store.log("entry-\(i)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertLessThanOrEqual(store.entries.count, 100)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testErrorLogEntryProperties() {
        let date = Date(timeIntervalSince1970: 1000)
        let entry = ErrorLogEntry(date: date, message: "test message")
        XCTAssertEqual(entry.message, "test message")
        XCTAssertEqual(entry.date, date)
        XCTAssertNotNil(entry.id)
    }
}
