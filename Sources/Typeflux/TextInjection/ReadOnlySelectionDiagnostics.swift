import ApplicationServices
import Foundation

/// Aggregates a bounded AX search, not just the focused node. A collapsed caret
/// in one node cannot establish that the rest of the window has no selection.
final class ReadOnlySelectionDiagnostics {
    var nodes = 0
    var roles: [String: Int] = [:]
    var positiveRanges = 0
    var emptySelections = 0
    var invalidValues = 0
    var treeTruncated = false
    private(set) var selectionReads = 0
    private(set) var unsupportedReads = 0
    private(set) var noValueReads = 0
    private(set) var failures = 0
    private(set) var cannotComplete = 0
    private(set) var errors: [String: Int] = [:]
    private let started = ProcessInfo.processInfo.systemUptime

    func record(_ attribute: String, error: AXError) {
        let selection = [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute,
                         kAXSelectedTextRangesAttribute].contains(attribute)
        if selection { selectionReads += 1 }
        guard error != .success else { return }
        errors["\(attribute):\(error.rawValue)", default: 0] += 1
        switch error {
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
            if selection { unsupportedReads += 1 }
        case .noValue:
            if selection { noValueReads += 1 }
        default:
            failures += 1
            if error == .cannotComplete { cannotComplete += 1 }
        }
    }

    func status(text: String?, budget: ReadOnlySelectionBudget) -> String {
        if text != nil { return "accessibility-context" }
        if budget.exhaustedReason != nil || treeTruncated { return "search-incomplete" }
        // CannotComplete can mean a timeout or an unresponsive application. Do not
        // mislabel it as a proven timeout; preserve the actual AX code in errors.
        if cannotComplete > 0 { return "ax-cannot-complete" }
        if failures > 0 { return "ax-error" }
        if positiveRanges > 0 { return "selection-unreadable" }
        if invalidValues > 0 { return "invalid-ax-value" }
        if emptySelections > 0 { return "no-selection-found" }
        if selectionReads > 0, unsupportedReads == selectionReads { return "ax-unsupported" }
        if noValueReads > 0 { return "ax-no-value" }
        return "selection-unavailable"
    }

    func details(budget: ReadOnlySelectionBudget) -> [String: Any] {
        ["nodes": nodes, "roles": roles, "positiveRanges": positiveRanges,
         "emptySelections": emptySelections, "invalidValues": invalidValues,
         "selectionReads": selectionReads, "unsupportedReads": unsupportedReads,
         "noValueReads": noValueReads, "axErrors": errors, "operations": budget.operations,
         "budgetStop": budget.exhaustedReason ?? "none", "treeTruncated": treeTruncated,
         "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)]
    }
}
