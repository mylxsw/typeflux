import XCTest
@testable import Typeflux

final class TextSelectionSnapshotTests: XCTestCase {

    func testHasSelectionIsFalseWhenSelectedTextIsNil() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = nil
        XCTAssertFalse(snapshot.hasSelection)
    }

    func testHasSelectionIsFalseWhenSelectedTextIsEmpty() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = ""
        XCTAssertFalse(snapshot.hasSelection)
    }

    func testHasSelectionIsFalseWhenSelectedTextIsWhitespaceOnly() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = "   \n\t  "
        XCTAssertFalse(snapshot.hasSelection)
    }

    func testHasSelectionIsTrueWhenSelectedTextHasContent() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = "Hello, world!"
        XCTAssertTrue(snapshot.hasSelection)
    }
}
