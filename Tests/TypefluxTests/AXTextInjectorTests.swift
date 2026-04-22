@testable import Typeflux
import XCTest

final class AXTextInjectorTests: XCTestCase {
    private final class InjectorBox: @unchecked Sendable {
        let value = AXTextInjector()
    }

    func testPerformAXReadOnMainActorRunsClosureOnMainThread() async {
        let injector = AXTextInjector()

        let isMainThread = await injector.performAXReadOnMainActor {
            Thread.isMainThread
        }

        XCTAssertTrue(isMainThread)
    }

    func testPerformAXOperationOnMainThreadRunsClosureOnMainThreadFromBackgroundQueue() async {
        let injector = InjectorBox()

        let isMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let value = injector.value.performAXOperationOnMainThread {
                    Thread.isMainThread
                }
                continuation.resume(returning: value)
            }
        }

        XCTAssertTrue(isMainThread)
    }

    func testShouldPreferEditableDescendantForWindowWhenCaretRangeExists() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0),
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate,
        )

        XCTAssertTrue(result)
    }

    func testShouldNotPreferEditableDescendantWhenWindowRoleDoesNotMatch() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0),
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXGroup",
            candidate: candidate,
        )

        XCTAssertFalse(result)
    }

    func testShouldNotPreferEditableDescendantWhenCandidateIsAlreadyFocused() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: true,
            selectedRange: CFRange(location: 0, length: 0),
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate,
        )

        XCTAssertFalse(result)
    }

    func testShouldNotPreferEditableDescendantWhenCandidateIsNotEditable() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: false,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0),
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate,
        )

        XCTAssertFalse(result)
    }

    func testShouldNotPreferEditableDescendantForScrollbarFalsePositive() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXScrollBar",
            isEditable: true,
            isFocused: false,
            selectedRange: nil,
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate,
        )

        XCTAssertFalse(result)
    }

    func testShouldTreatEmptyValueOnGenericEditableRoleAsUnreadable() {
        let result = AXTextInjector.shouldTreatAXValueAsUnreadable(
            role: "AXGroup",
            value: "",
            selectedRange: CFRange(location: 0, length: 0),
        )

        XCTAssertTrue(result)
    }

    func testShouldNotTreatEmptyValueOnNativeTextFieldAsUnreadable() {
        let result = AXTextInjector.shouldTreatAXValueAsUnreadable(
            role: "AXTextField",
            value: "",
            selectedRange: CFRange(location: 0, length: 0),
        )

        XCTAssertFalse(result)
    }

    func testEditableCandidateScoreRejectsScrollbarFalsePositive() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXScrollBar",
            isEditable: true,
            isFocused: false,
            selectedRange: nil,
        )

        XCTAssertEqual(AXTextInjector.editableCandidateScore(for: candidate), 0)
    }

    func testEditableCandidateScorePrefersGenericEditorWithCaret() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0),
        )

        XCTAssertGreaterThan(AXTextInjector.editableCandidateScore(for: candidate), 0)
    }

    func testShouldAllowClipboardSelectionReplacementWithoutAXBaseline() {
        let result = AXTextInjector.shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
            replaceSelection: true,
            selectionSource: "clipboard-copy",
            focusMatched: true,
            baselineAvailable: false,
        )

        XCTAssertTrue(result)
    }

    func testShouldNotAllowClipboardSelectionReplacementWithoutFocusMatch() {
        let result = AXTextInjector.shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
            replaceSelection: true,
            selectionSource: "clipboard-copy",
            focusMatched: false,
            baselineAvailable: false,
        )

        XCTAssertFalse(result)
    }

    func testShouldNotTreatNonEmptyValueAsUnreadable() {
        let result = AXTextInjector.shouldTreatAXValueAsUnreadable(
            role: "AXGroup",
            value: "hello",
            selectedRange: CFRange(location: 0, length: 0),
        )

        XCTAssertFalse(result)
    }

    func testEvaluatePasteVerificationReturnsSuccessWhenInsertedTextAppears() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello world",
            isEditable: true,
            isFocusedTarget: true,
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
            isFocusedTarget: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 99,
            processName: "Safari",
            role: "AXTextField",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
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
            isFocusedTarget: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
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
            isFocusedTarget: true,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXUnknown",
            text: nil,
            isEditable: true,
            isFocusedTarget: true,
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

    func testEvaluatePasteVerificationIsIndeterminateForInsertWhenFocusedElementIsNotReadable() {
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Codex",
            role: "AXWindow",
            text: nil,
            isEditable: false,
            isFocusedTarget: false,
            failureReason: "focused-element-not-editable",
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "hello",
            replaceSelection: false,
            targetProcessID: 42,
            before: nil,
            after: after,
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testEvaluatePasteVerificationStillFailsForReplaceWhenFocusedElementIsNotEditable() {
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Codex",
            role: "AXWindow",
            text: nil,
            isEditable: false,
            isFocusedTarget: false,
            failureReason: "focused-element-not-editable",
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "hello",
            replaceSelection: true,
            targetProcessID: 42,
            before: nil,
            after: after,
        )

        XCTAssertEqual(result, .failure("focused-element-not-editable"))
    }

    func testShouldActivateTargetBeforePasteReturnsFalseWhenFlagDisabled() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: false,
            targetProcessID: 42,
            frontmostProcessID: 99,
        )

        XCTAssertFalse(result)
    }

    func testShouldActivateTargetBeforePasteReturnsFalseWhenTargetMatchesFrontmost() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: 42,
            frontmostProcessID: 42,
        )

        XCTAssertFalse(result)
    }

    func testShouldActivateTargetBeforePasteReturnsFalseWhenTargetProcessIDMissing() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: nil,
            frontmostProcessID: 42,
        )

        XCTAssertFalse(result)
    }

    func testShouldActivateTargetBeforePasteReturnsTrueWhenTargetDiffersFromFrontmost() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: 42,
            frontmostProcessID: 99,
        )

        XCTAssertTrue(result)
    }

    func testShouldActivateTargetBeforePasteReturnsTrueWhenFrontmostIsNil() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: 42,
            frontmostProcessID: nil,
        )

        XCTAssertTrue(result)
    }

    func testShouldReactivateProcessForSelectionRestoreSkipsWhenAlreadyFrontmost() {
        // Chromium-based apps reset focus to the URL bar when activated while
        // already frontmost; the caller must not issue a redundant activate().
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: 42,
            frontmostProcessID: 42,
        )

        XCTAssertFalse(result)
    }

    func testShouldReactivateProcessForSelectionRestoreActivatesWhenTargetDiffers() {
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: 42,
            frontmostProcessID: 99,
        )

        XCTAssertTrue(result)
    }

    func testShouldReactivateProcessForSelectionRestoreActivatesWhenFrontmostUnknown() {
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: 42,
            frontmostProcessID: nil,
        )

        XCTAssertTrue(result)
    }

    func testShouldReactivateProcessForSelectionRestoreSkipsWhenTargetUnknown() {
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: nil,
            frontmostProcessID: 42,
        )

        XCTAssertFalse(result)
    }

    func testPasteEventDispatchMethodUsesHIDTapWhenFlagEnabled() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: true,
            targetProcessID: 42,
        )

        XCTAssertEqual(result, .hidTap)
    }

    func testPasteEventDispatchMethodUsesHIDTapWhenFlagEnabledAndTargetMissing() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: true,
            targetProcessID: nil,
        )

        XCTAssertEqual(result, .hidTap)
    }

    func testPasteEventDispatchMethodUsesPostToPidWhenFlagDisabledAndTargetAvailable() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: false,
            targetProcessID: 42,
        )

        XCTAssertEqual(result, .postToPid)
    }

    func testPasteEventDispatchMethodFallsBackToHIDTapWhenFlagDisabledAndTargetMissing() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: false,
            targetProcessID: nil,
        )

        XCTAssertEqual(result, .hidTap)
    }

    func testShouldPerformStrictPasteVerificationReturnsFalseForInsertEvenWhenFlagEnabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: false,
            strictFallbackEnabled: true,
        )

        XCTAssertFalse(result)
    }

    func testShouldPerformStrictPasteVerificationReturnsFalseForReplaceWhenFlagDisabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: true,
            strictFallbackEnabled: false,
        )

        XCTAssertFalse(result)
    }

    func testShouldPerformStrictPasteVerificationReturnsTrueForReplaceWhenFlagEnabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: true,
            strictFallbackEnabled: true,
        )

        XCTAssertTrue(result)
    }

    func testShouldPerformStrictPasteVerificationReturnsFalseForInsertWhenFlagDisabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: false,
            strictFallbackEnabled: false,
        )

        XCTAssertFalse(result)
    }

    func testEvaluatePasteVerificationIsIndeterminateWhenReadableTextIsUnchangedOnHeuristicTarget() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Google Chrome",
            role: "AXTextField",
            text: "x.com/home",
            isEditable: true,
            isFocusedTarget: false,
            failureReason: nil,
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Google Chrome",
            role: "AXTextField",
            text: "x.com/home",
            isEditable: true,
            isFocusedTarget: false,
            failureReason: nil,
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "The input method is not feasible in this scenario.",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after,
        )

        XCTAssertEqual(result, .indeterminate)
    }
}
