@testable import Typeflux
import XCTest

final class InputContextSnapshotTests: XCTestCase {
    func testMakeReturnsNilWhenFeatureCannotReadFocusedEditableText() {
        let snapshot = CurrentInputTextSnapshot(
            processName: "Notes",
            text: "Hello world",
            selectedRange: CFRange(location: 5, length: 0),
            isEditable: true,
            isFocusedTarget: false,
        )

        XCTAssertNil(InputContextSnapshot.make(inputSnapshot: snapshot, selectionSnapshot: TextSelectionSnapshot()))
    }

    func testMakeSplitsTextAroundCursorAndAppliesLimits() {
        let input = CurrentInputTextSnapshot(
            processName: "Notes",
            role: "AXTextArea",
            text: "0123456789abcdefghij",
            selectedRange: CFRange(location: 10, length: 0),
            isEditable: true,
            isFocusedTarget: true,
        )

        let context = InputContextSnapshot.make(
            inputSnapshot: input,
            selectionSnapshot: TextSelectionSnapshot(),
            prefixLimit: 4,
            suffixLimit: 3,
        )

        XCTAssertEqual(context?.appName, "Notes")
        XCTAssertEqual(context?.role, "AXTextArea")
        XCTAssertEqual(context?.prefix, "6789")
        XCTAssertEqual(context?.suffix, "abc")
        XCTAssertNil(context?.selectedText)
    }

    func testMakeIncludesBoundedSelectedText() {
        let input = CurrentInputTextSnapshot(
            processName: "Notes",
            text: "before selected after",
            selectedRange: CFRange(location: 7, length: 8),
            isEditable: true,
            isFocusedTarget: true,
        )

        var selection = TextSelectionSnapshot()
        selection.selectedText = "selected"

        let context = InputContextSnapshot.make(
            inputSnapshot: input,
            selectionSnapshot: selection,
            selectionLimit: 4,
        )

        XCTAssertEqual(context?.prefix, "before ")
        XCTAssertEqual(context?.selectedText, "sele")
        XCTAssertEqual(context?.suffix, " after")
    }

    func testMakeReturnsNilWhenRangeIsUnreliable() {
        let input = CurrentInputTextSnapshot(
            processName: "Notes",
            text: "short",
            selectedRange: CFRange(location: 99, length: 0),
            isEditable: true,
            isFocusedTarget: true,
        )

        XCTAssertNil(InputContextSnapshot.make(inputSnapshot: input, selectionSnapshot: TextSelectionSnapshot()))
    }
}
