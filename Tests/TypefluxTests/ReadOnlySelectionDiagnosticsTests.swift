import AppKit
import ApplicationServices
import XCTest
@testable import Typeflux

final class ReadOnlySelectionDiagnosticsTests: XCTestCase {
    private func range(_ location: Int, _ length: Int) -> AXValue {
        var value = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &value)!
    }

    private func read(_ values: [String: AnyObject] = [:], error: AXError = .attributeUnsupported,
                      diagnostics: ReadOnlySelectionDiagnostics, budget: ReadOnlySelectionBudget) -> String? {
        AXTextInjector().readOnlySelectedText(
            from: AXUIElementCreateSystemWide(), budget: budget, diagnostics: diagnostics,
            attributeRead: { name in values[name].map { (.success, $0) } ?? (error, nil) },
            parameterizedText: { _ in nil }
        )
    }

    func testUnsupportedNoValueAndErrorsRemainDistinctFromNoSelection() {
        for (error, status) in [(AXError.attributeUnsupported, "ax-unsupported"),
                                (.notImplemented, "ax-unsupported"), (.noValue, "ax-no-value"),
                                (.cannotComplete, "ax-cannot-complete"), (.invalidUIElement, "ax-error")] {
            let diagnostics = ReadOnlySelectionDiagnostics()
            let budget = ReadOnlySelectionBudget()
            XCTAssertNil(read(error: error, diagnostics: diagnostics, budget: budget))
            XCTAssertEqual(diagnostics.status(text: nil, budget: budget), status)
            XCTAssertEqual(diagnostics.errors["AXSelectedText:\(error.rawValue)"], 1)
            XCTAssertEqual(diagnostics.emptySelections, 0)
        }
    }

    func testEmptyTextCollapsedRangeAndEmptyMultiRangeReportNoSelectionFound() {
        for values: [String: AnyObject] in [
            [kAXSelectedTextAttribute: "" as NSString],
            [kAXSelectedTextAttribute: " \n\t" as NSString],
            [kAXSelectedTextRangeAttribute: range(4, 0)],
            [kAXSelectedTextRangesAttribute: [] as NSArray]
        ] {
            let diagnostics = ReadOnlySelectionDiagnostics()
            let budget = ReadOnlySelectionBudget()
            XCTAssertNil(read(values, diagnostics: diagnostics, budget: budget))
            XCTAssertEqual(diagnostics.status(text: nil, budget: budget), "no-selection-found")
        }
    }

    func testUnreadableChildRangeWinsOverFocusedCollapsedCaret() {
        let diagnostics = ReadOnlySelectionDiagnostics()
        let budget = ReadOnlySelectionBudget()
        let result = ReadOnlySelection.find(
            roots: [0], budget: budget,
            read: { node in self.read([kAXSelectedTextRangeAttribute: self.range(0, node == 0 ? 0 : 3)],
                                      diagnostics: diagnostics, budget: budget) },
            children: { $0 == 0 ? [1] : [] }, matches: ==
        )
        XCTAssertNil(result)
        XCTAssertEqual(diagnostics.nodes, 2)
        XCTAssertEqual(diagnostics.status(text: nil, budget: budget), "selection-unreadable")
    }

    func testReadableChildStillWinsAfterCollapsedCaretAndUnsupportedAttributes() {
        let diagnostics = ReadOnlySelectionDiagnostics()
        let budget = ReadOnlySelectionBudget()
        let result = ReadOnlySelection.find(
            roots: [0], budget: budget,
            read: { node in self.read(node == 0 ? [kAXSelectedTextRangeAttribute: self.range(0, 0)] : [
                kAXSelectedTextAttribute: "中文😀" as NSString, kAXRoleAttribute: "AXStaticText" as NSString
            ], diagnostics: diagnostics, budget: budget) },
            children: { $0 == 0 ? [1] : [] }, matches: ==
        )
        XCTAssertEqual(result?.text, "中文😀")
        XCTAssertEqual(diagnostics.roles["AXStaticText"], 1)
        XCTAssertEqual(diagnostics.status(text: result?.text, budget: budget), "accessibility-context")
    }

    func testMalformedRangesAreNotClassifiedAsAbsent() {
        for values: [String: AnyObject] in [
            [kAXSelectedTextRangeAttribute: "bad" as NSString],
            [kAXSelectedTextRangeAttribute: range(-1, 0)],
            [kAXSelectedTextRangesAttribute: "bad" as NSString],
            [kAXSelectedTextRangesAttribute: [range(0, 0), "bad"] as NSArray],
            [kAXSelectedTextAttribute: 42 as NSNumber]
        ] {
            let diagnostics = ReadOnlySelectionDiagnostics()
            let budget = ReadOnlySelectionBudget()
            XCTAssertNil(read(values, diagnostics: diagnostics, budget: budget))
            XCTAssertEqual(diagnostics.status(text: nil, budget: budget), "invalid-ax-value")
        }
    }

    func testBudgetAndTreeLimitsAreNotMistakenForNoSelection() {
        let diagnostics = ReadOnlySelectionDiagnostics()
        let budget = ReadOnlySelectionBudget(operations: 1)
        XCTAssertNil(read([kAXSelectedTextAttribute: "" as NSString], diagnostics: diagnostics, budget: budget))
        XCTAssertEqual(diagnostics.status(text: nil, budget: budget), "search-incomplete")
        XCTAssertEqual(budget.exhaustedReason, "operations")
        var time = 0.0
        let deadline = ReadOnlySelectionBudget(seconds: 1, now: { time })
        time = 2
        XCTAssertFalse(deadline.take())
        XCTAssertEqual(deadline.exhaustedReason, "deadline")
        XCTAssertEqual(diagnostics.status(text: nil, budget: deadline), "search-incomplete")
        let treeBudget = ReadOnlySelectionBudget(operations: 1000)
        _ = ReadOnlySelection.find(roots: [0], budget: treeBudget, read: { _ in nil as String? },
                                  children: { _ in Array(1...100) }, matches: ==,
                                  onTruncation: { diagnostics.treeTruncated = true })
        XCTAssertTrue(diagnostics.treeTruncated)
        XCTAssertEqual(diagnostics.status(text: nil, budget: treeBudget), "search-incomplete")
    }

    func testUnavailableWithoutEvidenceAndPrivacySafeDiagnosticMetadata() throws {
        let diagnostics = ReadOnlySelectionDiagnostics()
        let budget = ReadOnlySelectionBudget()
        XCTAssertEqual(diagnostics.status(text: nil, budget: budget), "selection-unavailable")
        let request = ReadOnlySelectionRequest(processID: 42, processName: "Test\nApp", bundleIdentifier: "test.app",
            nativeSnapshot: TextSelectionSnapshot(selectedText: "SECRET_SELECTION", windowTitle: "SECRET_TITLE"))
        let message = try XCTUnwrap(request.diagnosticMessage(status: "ax-unsupported", details: diagnostics.details(budget: budget)))
        XCTAssertFalse(message.contains("SECRET"))
        XCTAssertFalse(message.contains("\n"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        XCTAssertEqual(json["captureID"] as? String, request.id.uuidString)
        XCTAssertEqual(json["pid"] as? Int, 42)
        XCTAssertEqual(json["app"] as? String, "Test\nApp")
        XCTAssertEqual(json["clipboardProbe"] as? String, "disabled")
        XCTAssertNotNil(json["axErrors"])
        XCTAssertNotNil(json["elapsedMS"])
        XCTAssertTrue(request.matches(processID: 42))
        XCTAssertFalse(request.matches(processID: 99))
        XCTAssertFalse(ReadOnlySelectionRequest().matches(processID: nil))
    }
}
