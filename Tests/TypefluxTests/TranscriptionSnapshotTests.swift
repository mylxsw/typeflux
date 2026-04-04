import XCTest
@testable import Typeflux

final class TranscriptionSnapshotTests: XCTestCase {

    func testCreateWithIsFinalTrue() {
        let snapshot = TranscriptionSnapshot(text: "Hello world", isFinal: true)
        XCTAssertEqual(snapshot.text, "Hello world")
        XCTAssertTrue(snapshot.isFinal)
    }

    func testCreateWithIsFinalFalse() {
        let snapshot = TranscriptionSnapshot(text: "partial", isFinal: false)
        XCTAssertEqual(snapshot.text, "partial")
        XCTAssertFalse(snapshot.isFinal)
    }
}
