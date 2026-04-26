@testable import Typeflux
import XCTest

final class InputContextSnapshotTests: XCTestCase {
    func testMakeReturnsNilWhenInputIsNotEditable() {
        let snapshot = CurrentInputTextSnapshot(
            processName: "Notes",
            text: "Hello world",
            selectedRange: CFRange(location: 5, length: 0),
            isEditable: false,
            isFocusedTarget: false,
        )

        XCTAssertNil(InputContextSnapshot.make(inputSnapshot: snapshot, selectionSnapshot: TextSelectionSnapshot()))
    }

    func testMakeAllowsFocusedElementWhenFocusedAttributeIsFalse() {
        let snapshot = CurrentInputTextSnapshot(
            processName: "Notes",
            text: "Hello world",
            selectedRange: CFRange(location: 5, length: 0),
            isEditable: true,
            isFocusedTarget: false,
        )

        let context = InputContextSnapshot.make(
            inputSnapshot: snapshot,
            selectionSnapshot: TextSelectionSnapshot(),
        )

        XCTAssertEqual(context?.prefix, "Hello")
        XCTAssertEqual(context?.suffix, " world")
        XCTAssertFalse(context?.isFocusedTarget ?? true)
    }

    func testMakeFallsBackToSelectionWhenFocusedElementIsNotEditable() {
        let input = CurrentInputTextSnapshot(
            processName: "Zed",
            bundleIdentifier: "dev.zed.Zed",
            role: "AXWindow",
            text: nil,
            selectedRange: nil,
            isEditable: false,
            isFocusedTarget: true,
            failureReason: "focused-element-not-editable",
        )

        var selection = TextSelectionSnapshot()
        selection.processName = "Zed"
        selection.bundleIdentifier = "dev.zed.Zed"
        selection.selectedText = "Selected markdown paragraph"
        selection.source = "clipboard-copy"
        selection.isFocusedTarget = true

        let context = InputContextSnapshot.make(
            inputSnapshot: input,
            selectionSnapshot: selection,
            selectionLimit: 8,
        )

        XCTAssertEqual(context?.appName, "Zed")
        XCTAssertEqual(context?.bundleIdentifier, "dev.zed.Zed")
        XCTAssertEqual(context?.role, "AXWindow")
        XCTAssertFalse(context?.isEditable ?? true)
        XCTAssertTrue(context?.isFocusedTarget ?? false)
        XCTAssertEqual(context?.prefix, "")
        XCTAssertEqual(context?.selectedText, "Selected")
        XCTAssertEqual(context?.suffix, "")
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
