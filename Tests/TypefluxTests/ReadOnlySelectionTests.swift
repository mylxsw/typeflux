import AppKit
import ApplicationServices
import XCTest
@testable import Typeflux

final class ReadOnlySelectionTests: XCTestCase {
    private func axRange(_ location: Int, _ length: Int) -> AXValue {
        var range = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &range)!
    }

    private func readAX(_ attributes: [String: AnyObject], operations: Int = 96,
                        parameterizedText: @escaping (CFRange) -> String? = { _ in nil }) -> String? {
        AXTextInjector().readOnlySelectedText(
            from: AXUIElementCreateSystemWide(), budget: ReadOnlySelectionBudget(operations: operations),
            attributeValue: { attributes[$0] }, parameterizedText: parameterizedText
        )
    }

    func testAXReadsAttributedSelectionWithoutRange() {
        XCTAssertEqual(readAX([
            kAXSelectedTextAttribute: NSAttributedString(string: "selected"),
            kAXRoleAttribute: "AXStaticText" as NSString
        ]), "selected")
    }

    func testAXDoesNotTreatWholeContainerValueOrPlaceholderAsSelection() {
        XCTAssertNil(readAX([
            kAXSelectedTextAttribute: "whole message" as NSString,
            kAXValueAttribute: "whole message" as NSString,
            kAXRoleAttribute: "AXGroup" as NSString
        ]))
        XCTAssertNil(readAX([
            kAXSelectedTextAttribute: "placeholder" as NSString,
            kAXPlaceholderValueAttribute: "placeholder" as NSString
        ]))
    }

    func testAXSingleRangeUsesParameterizedText() {
        XCTAssertEqual(readAX([kAXSelectedTextRangeAttribute: axRange(2, 2)], parameterizedText: { range in
            XCTAssertEqual(range.location, 2)
            return "中文"
        }), "中文")
    }

    func testAXMultipleRangesFallbackToAttributedValue() {
        XCTAssertEqual(readAX([
            kAXSelectedTextRangeAttribute: axRange(0, 0),
            kAXSelectedTextRangesAttribute: [axRange(1, 2), axRange(3, 2)] as NSArray,
            kAXValueAttribute: NSAttributedString(string: "a😀中文z")
        ]), "😀\n中文")
    }

    func testAXInvalidRangeTypesAndMixedRangesAreRejected() {
        var point = CGPoint.zero
        let pointValue = AXValueCreate(.cgPoint, &point)!
        for invalid in ["not a range" as AnyObject, pointValue] {
            XCTAssertNil(readAX([
                kAXSelectedTextRangeAttribute: invalid,
                kAXSelectedTextRangesAttribute: [axRange(0, 1), invalid] as NSArray,
                kAXValueAttribute: "full text" as NSString
            ]))
        }
    }

    func testAXBudgetExhaustionCannotBypassValidation() {
        XCTAssertNil(readAX([
            kAXSelectedTextAttribute: "whole message" as NSString,
            kAXValueAttribute: "whole message" as NSString,
            kAXRoleAttribute: "AXGroup" as NSString
        ], operations: 2))
        XCTAssertNil(readAX([kAXSelectedTextRangeAttribute: axRange(0, 1)], operations: 2,
                            parameterizedText: { _ in XCTFail(); return "x" }))
        XCTAssertNil(readAX([:], operations: 0))
    }

    func testDirectSelectionAvoidsRangeAndValueReads() {
        let text = ReadOnlySelection.text(
            selectedText: { " selected " }, ranges: { XCTFail(); return [] },
            stringForRange: { _ in XCTFail(); return nil }, value: { XCTFail(); return nil }
        )
        XCTAssertEqual(text, " selected ")
    }

    func testParameterizedRangeDoesNotNeedFullValue() {
        let text = ReadOnlySelection.text(
            selectedText: { nil }, ranges: { [CFRange(location: 10, length: 2)] },
            stringForRange: { _ in "中文" }, value: { XCTFail(); return nil }
        )
        XCTAssertEqual(text, "中文")
    }

    func testValueFallbackUsesUTF16AndReadsValueOnceForMultipleRanges() {
        var reads = 0
        let text = ReadOnlySelection.text(
            selectedText: { " " },
            ranges: { [CFRange(location: 1, length: 2), CFRange(location: 3, length: 2)] },
            stringForRange: { _ in nil }, value: { reads += 1; return "a😀中文z" }
        )
        XCTAssertEqual(text, "😀\n中文")
        XCTAssertEqual(reads, 1)
    }

    func testMalformedRangesNeverReadText() {
        for range in [CFRange(location: -1, length: 1), CFRange(location: 0, length: 0),
                      CFRange(location: 0, length: -1), CFRange(location: Int.max, length: 2)] {
            XCTAssertNil(ReadOnlySelection.text(
                selectedText: { nil }, ranges: { [range] },
                stringForRange: { _ in XCTFail(); return nil }, value: { XCTFail(); return nil }
            ))
        }
    }

    func testMissingAndExcessiveRangesDoNotReadWholeValue() {
        for ranges in [[], Array(repeating: CFRange(location: 0, length: 1), count: 17)] {
            XCTAssertNil(ReadOnlySelection.text(
                selectedText: { nil }, ranges: { ranges },
                stringForRange: { _ in XCTFail(); return nil }, value: { XCTFail(); return nil }
            ))
        }
    }

    func testOutOfBoundsOrSplitSurrogateRangeIsRejected() {
        for range in [CFRange(location: 10, length: 1), CFRange(location: 1, length: 1)] {
            XCTAssertNil(ReadOnlySelection.text(
                selectedText: { nil }, ranges: { [range] },
                stringForRange: { _ in nil }, value: { "😀x" }
            ))
        }
    }

    func testIncorrectParameterizedLengthFallsBackToValue() {
        XCTAssertEqual(ReadOnlySelection.text(
            selectedText: { nil }, ranges: { [CFRange(location: 1, length: 2)] },
            stringForRange: { _ in "entire value" }, value: { "abcd" }
        ), "bc")
    }

    func testIncompleteMultiRangeAndWhitespaceSelectionAreRejected() {
        XCTAssertNil(ReadOnlySelection.text(
            selectedText: { nil }, ranges: { [CFRange(location: 0, length: 2), CFRange(location: 3, length: 2)] },
            stringForRange: { $0.location == 0 ? "ab" : nil }, value: { nil }
        ))
        XCTAssertNil(ReadOnlySelection.text(
            selectedText: { nil }, ranges: { [CFRange(location: 0, length: 2)] },
            stringForRange: { _ in " \n" }, value: { nil }
        ))
    }

    func testFindsNonFocusedMessageChild() {
        let result = ReadOnlySelection.find(
            roots: ["input", "window"], budget: ReadOnlySelectionBudget(),
            read: { $0 == "message" ? "selected message" : nil },
            children: { $0 == "window" ? ["input", "message"] : [] }, matches: ==
        )
        XCTAssertEqual(result?.node, "message")
        XCTAssertEqual(result?.text, "selected message")
    }

    func testFocusedSelectionWinsOverOtherWindowChildren() {
        let result = ReadOnlySelection.find(
            roots: ["input", "window"], budget: ReadOnlySelectionBudget(),
            read: { $0 == "input" ? "focused selection" : "other selection" },
            children: { _ in XCTFail(); return [] }, matches: ==
        )
        XCTAssertEqual(result?.node, "input")
    }

    func testCyclesAndDuplicateRootsAreReadOnce() {
        var visited: [Int] = []
        XCTAssertNil(ReadOnlySelection.find(
            roots: [0, 0], budget: ReadOnlySelectionBudget(),
            read: { visited.append($0); return " " },
            children: { $0 == 0 ? [1] : [0] }, matches: ==
        ))
        XCTAssertEqual(visited, [0, 1])
    }

    func testOperationBudgetAndDeadlineStopTraversal() {
        var visited: [Int] = []
        XCTAssertNil(ReadOnlySelection.find(
            roots: [0], budget: ReadOnlySelectionBudget(operations: 2),
            read: { visited.append($0); return nil }, children: { [$0 + 1] }, matches: ==
        ))
        XCTAssertEqual(visited, [0, 1])
        var time = 0.0
        let budget = ReadOnlySelectionBudget(seconds: 1, now: { time })
        XCTAssertNil(ReadOnlySelection.find(
            roots: [0], budget: budget, read: { _ in time = 2; return nil },
            children: { [$0 + 1] }, matches: ==
        ))
        XCTAssertFalse(budget.take())
    }

    func testWideTreeIsBoundedAndEmptyTreeHasNoResult() {
        var reads = 0
        let children: (Int) -> [Int] = { node in
            let start = node * 100 + 1
            return Array(start..<(start + 100))
        }
        XCTAssertNil(ReadOnlySelection.find(
            roots: [0], budget: ReadOnlySelectionBudget(operations: 1000),
            read: { (_: Int) -> String? in reads += 1; return nil },
            children: children, matches: { $0 == $1 }
        ))
        XCTAssertEqual(reads, 96)
        XCTAssertNil(ReadOnlySelection.find(
            roots: [Int](), budget: ReadOnlySelectionBudget(), read: { _ in XCTFail(); return nil },
            children: { _ in XCTFail(); return [] }, matches: ==
        ))
    }

    func testReadOnlyContextCannotAuthorizeReplacement() {
        let snapshot = TextSelectionSnapshot(
            selectedRange: CFRange(location: 0, length: 3), selectedText: "abc", source: "accessibility",
            isEditable: true, isFocusedTarget: true, replacementContextID: UUID(),
            replacementSafety: .directAccessibility, nativeTarget: NativeTextSelectionTarget()
        ).readOnlyContext()
        XCTAssertTrue(snapshot.hasAskSelectionContext)
        XCTAssertFalse(snapshot.canReplaceSelection)
        XCTAssertFalse(snapshot.canSafelyRestoreSelection)
        XCTAssertNil(snapshot.replacementContextID)
        XCTAssertNil(snapshot.nativeTarget)
        XCTAssertEqual(snapshot.replacementSafety, .resultOnly)
        XCTAssertEqual(TextSelectionSnapshot().readOnlyContext().replacementSafety, SelectionReplacementSafety.none)
        for source in ["accessibility", "clipboard-copy"] {
            XCTAssertEqual(AXTextInjector.replacementSafety(
                source: source, selectedRange: CFRange(location: 0, length: 3),
                isEditable: true, isFocusedTarget: true, selectedText: "abc",
                intent: .readOnlyContext, capability: .writable
            ), .resultOnly)
        }
    }

    func testReadOnlyProbeAllowsMissingRangeWhileDictationStillRejectsIt() {
        XCTAssertTrue(AXTextInjector.shouldProbeClipboardSelection(selectedRange: nil, intent: .readOnlyContext))
        XCTAssertFalse(AXTextInjector.shouldProbeClipboardSelection(selectedRange: nil, intent: .automaticInsertion))
        XCTAssertFalse(AXTextInjector.shouldProbeClipboardSelection(
            selectedRange: CFRange(location: 0, length: 0), intent: .automaticInsertion
        ))
    }

    func testCapturePrefersAXAndOnlyCopiesWhenAXIsUnavailable() throws {
        let ax = try ReadOnlySelection.capture(
            readAX: { "selection" }, copy: { XCTFail(); return nil },
            targetMatches: { true }, checkCancellation: {}
        )
        XCTAssertEqual(ax.text, "selection")
        XCTAssertEqual(ax.source, "accessibility-context")
        for copied in ["selection", nil] {
            var copies = 0
            let result = try ReadOnlySelection.capture(
                readAX: { nil }, copy: { copies += 1; return copied },
                targetMatches: { true }, checkCancellation: {}
            )
            XCTAssertEqual(copies, 1)
            XCTAssertEqual(result.text, copied)
            XCTAssertEqual(result.source, copied == nil ? "none" : "clipboard-copy")
        }
    }

    func testTargetChangeDiscardsTextAndPreventsCopyIntoAnotherApp() throws {
        for selected in ["old selection", nil] {
            let result = try ReadOnlySelection.capture(
                readAX: { selected }, copy: { XCTFail(); return nil },
                targetMatches: { false }, checkCancellation: {}
            )
            XCTAssertNil(result.text)
            XCTAssertEqual(result.source, "target-changed")
        }
        var matches = true
        let result = try ReadOnlySelection.capture(
            readAX: { nil }, copy: { matches = false; return "unrelated text" },
            targetMatches: { matches }, checkCancellation: {}
        )
        XCTAssertNil(result.text)
        XCTAssertEqual(result.source, "target-changed")
    }

    func testCancellationBeforeReadOrCopyOrAfterCopyDiscardsCapture() {
        for cancellationStep in 1...3 {
            var checks = 0
            var copies = 0
            XCTAssertThrowsError(try ReadOnlySelection.capture(
                readAX: { if cancellationStep == 1 { XCTFail() }; return nil },
                copy: { copies += 1; return "copied" }, targetMatches: { true },
                checkCancellation: {
                    checks += 1
                    if checks == cancellationStep { throw CancellationError() }
                }
            ))
            XCTAssertEqual(copies, cancellationStep == 3 ? 1 : 0)
        }
    }
}
