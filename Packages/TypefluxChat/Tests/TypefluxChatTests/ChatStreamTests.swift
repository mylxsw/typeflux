import XCTest
@testable import TypefluxChat

let chatSnapshot = #"{"id":"chat","title":"Hello","revision":1,"updated_at":"2026-01-02T03:04:05Z","messages":[{"id":"m","role":"user","text":"hello","created_at":"2026-01-02T03:04:05Z"}],"harness":{"future":"ignored"}}"#
let chatProgress = #"{"id":"chat","revision":2,"updated_at":"2026-01-02T03:04:06Z","run":{"id":"run","device_id":"phone","status":"running","updated_at":"2026-01-02T03:04:06Z","pending":[],"preview":"Hi"}}"#

final class ChatStreamTests: XCTestCase {
    func testProgressPreservesHistoryAndRejectsStaleOrForeignFrames() throws {
        var state = ChatConversationStreamState()
        XCTAssertNil(try state.consume(event: "progress", data: chatProgress))
        XCTAssertEqual(try state.consume(event: "snapshot", data: chatSnapshot)?.messages.count, 1)
        XCTAssertNil(try state.consume(event: "snapshot", data: chatSnapshot))
        let updated = try state.consume(event: "progress", data: chatProgress)
        XCTAssertEqual(updated?.run?.preview, "Hi")
        XCTAssertEqual(updated?.messages.first?.text, "hello")
        XCTAssertNil(try state.consume(event: "progress", data: chatProgress))
        XCTAssertNil(try state.consume(event: "snapshot", data: chatSnapshot))
        XCTAssertNil(try state.consume(event: "progress", data: chatProgress.replacingOccurrences(of: "chat", with: "another")))
        XCTAssertNil(try state.consume(event: "future-event", data: "not JSON"))
        XCTAssertEqual(state.value?.revision, 2)
        XCTAssertEqual(try state.consume(event: "snapshot", data: chatSnapshot.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":3"))?.revision, 3)
    }

    func testUnavailableAndInvalidSnapshotsFailWithoutDestroyingLastState() throws {
        var state = ChatConversationStreamState()
        _ = try state.consume(event: "snapshot", data: chatSnapshot)
        XCTAssertThrowsError(try state.consume(event: "unavailable", data: "{}")) { XCTAssertEqual($0 as? ChatAPIError, .unavailable) }
        XCTAssertThrowsError(try state.consume(event: "snapshot", data: "not JSON"))
        XCTAssertEqual(state.value?.revision, 1)
    }
}
