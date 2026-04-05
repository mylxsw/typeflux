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

    func testHasAskSelectionContextRequiresFocusAndSelection() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = "Selected"
        snapshot.isFocusedTarget = true

        XCTAssertTrue(snapshot.hasAskSelectionContext)
    }

    func testCanReplaceSelectionRequiresEditableFocusedSelection() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = "Editable"
        snapshot.isFocusedTarget = true
        snapshot.isEditable = true
        snapshot.source = "accessibility"

        XCTAssertTrue(snapshot.canReplaceSelection)
        XCTAssertTrue(snapshot.canSafelyRestoreSelection)
    }

    func testClipboardSelectionCanBeReplaceableButNotSafelyRestorable() {
        var snapshot = TextSelectionSnapshot()
        snapshot.selectedText = "Read only selection"
        snapshot.isFocusedTarget = true
        snapshot.isEditable = true
        snapshot.source = "clipboard-copy"

        XCTAssertTrue(snapshot.canReplaceSelection)
        XCTAssertFalse(snapshot.canSafelyRestoreSelection)
    }
}
