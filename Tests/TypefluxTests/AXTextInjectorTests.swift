@testable import Typeflux
import XCTest

final class AXTextInjectorTests: XCTestCase {
    func testEvaluatePasteVerificationReturnsSuccessWhenInsertedTextAppears() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello world",
            isEditable: true,
            failureReason: nil,
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after,
        )

        XCTAssertEqual(result, .success)
    }

    func testEvaluatePasteVerificationFailsWhenFocusedProcessChanges() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 99,
            processName: "Safari",
            role: "AXTextField",
            text: "Hello",
            isEditable: true,
            failureReason: nil,
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after,
        )

        XCTAssertEqual(result, .failure("focused-process-changed"))
    }

    func testEvaluatePasteVerificationFailsWhenReadableInputTextDoesNotChange() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            failureReason: nil,
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after,
        )

        XCTAssertEqual(result, .failure("input-text-unchanged"))
    }

    func testEvaluatePasteVerificationIsIndeterminateWhenTextCannotBeReadBack() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXUnknown",
            text: nil,
            isEditable: true,
            failureReason: "missing-ax-value",
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after,
        )

        XCTAssertEqual(result, .indeterminate)
    }
}
