import Foundation

struct InputContextSnapshot: Equatable {
    static let defaultPrefixLimit = 500
    static let defaultSuffixLimit = 200
    static let defaultSelectionLimit = 2_000

    let appName: String?
    let bundleIdentifier: String?
    let role: String?
    let isEditable: Bool
    let isFocusedTarget: Bool
    let prefix: String
    let suffix: String
    let selectedText: String?

    var hasContent: Bool {
        !prefix.isEmpty || !suffix.isEmpty || !(selectedText?.isEmpty ?? true)
    }

    static func make(
        inputSnapshot: CurrentInputTextSnapshot,
        selectionSnapshot: TextSelectionSnapshot,
        prefixLimit: Int = defaultPrefixLimit,
        suffixLimit: Int = defaultSuffixLimit,
        selectionLimit: Int = defaultSelectionLimit,
    ) -> InputContextSnapshot? {
        guard inputSnapshot.isEditable else {
            return selectionOnlyContext(
                inputSnapshot: inputSnapshot,
                selectionSnapshot: selectionSnapshot,
                selectionLimit: selectionLimit,
            )
        }
        guard let text = inputSnapshot.text, !text.isEmpty else {
            return selectionOnlyContext(
                inputSnapshot: inputSnapshot,
                selectionSnapshot: selectionSnapshot,
                selectionLimit: selectionLimit,
            )
        }
        guard
            let selectedRange = inputSnapshot.selectedRange,
            let range = stringRange(from: selectedRange, in: text)
        else {
            return selectionOnlyContext(
                inputSnapshot: inputSnapshot,
                selectionSnapshot: selectionSnapshot,
                selectionLimit: selectionLimit,
            )
        }

        let selected = normalizedSelectedText(
            selectionSnapshot.selectedText,
            fallback: String(text[range]),
            limit: selectionLimit,
        )
        let prefix = String(text[..<range.lowerBound]).suffixCharacters(prefixLimit)
        let suffix = String(text[range.upperBound...]).prefixCharacters(suffixLimit)

        let snapshot = InputContextSnapshot(
            appName: inputSnapshot.processName ?? selectionSnapshot.processName,
            bundleIdentifier: inputSnapshot.bundleIdentifier ?? selectionSnapshot.bundleIdentifier,
            role: inputSnapshot.role ?? selectionSnapshot.role,
            isEditable: inputSnapshot.isEditable,
            isFocusedTarget: inputSnapshot.isFocusedTarget || selectionSnapshot.isFocusedTarget,
            prefix: prefix,
            suffix: suffix,
            selectedText: selected,
        )
        return snapshot.hasContent ? snapshot : nil
    }

    static func logCapture(
        inputSnapshot: CurrentInputTextSnapshot,
        selectionSnapshot: TextSelectionSnapshot,
        context: InputContextSnapshot?,
    ) {
        let selectedRangeDescription = inputSnapshot.selectedRange.map {
            "location=\($0.location), length=\($0.length)"
        } ?? "<nil>"
        let selectionRangeDescription = selectionSnapshot.selectedRange.map {
            "location=\($0.location), length=\($0.length)"
        } ?? "<nil>"
        let status = context == nil ? "skipped" : "captured"
        let skipReason = context == nil
            ? inputContextSkipReason(inputSnapshot: inputSnapshot, selectionSnapshot: selectionSnapshot)
            : "<none>"

        NetworkDebugLogger.logMessage(
            """
            [InputContext]
            status: \(status)
            skipReason: \(skipReason)
            inputFailureReason: \(inputSnapshot.failureReason ?? "<nil>")
            appName: \(inputSnapshot.processName ?? selectionSnapshot.processName ?? "<nil>")
            bundleIdentifier: \(inputSnapshot.bundleIdentifier ?? selectionSnapshot.bundleIdentifier ?? "<nil>")
            role: \(inputSnapshot.role ?? selectionSnapshot.role ?? "<nil>")
            inputIsEditable: \(inputSnapshot.isEditable)
            inputIsFocusedTarget: \(inputSnapshot.isFocusedTarget)
            selectionSource: \(selectionSnapshot.source)
            selectionIsEditable: \(selectionSnapshot.isEditable)
            selectionIsFocusedTarget: \(selectionSnapshot.isFocusedTarget)
            selectedRange: \(selectedRangeDescription)
            selectionSelectedRange: \(selectionRangeDescription)
            inputTextLength: \(inputSnapshot.text?.count ?? 0)
            selectedTextLength: \(context?.selectedText?.count ?? 0)
            prefix(\(context?.prefix.count ?? 0)):
            \(context?.prefix ?? "")
            selectedText(\(context?.selectedText?.count ?? 0)):
            \(context?.selectedText ?? "")
            suffix(\(context?.suffix.count ?? 0)):
            \(context?.suffix ?? "")
            """,
        )
    }

    private static func selectionOnlyContext(
        inputSnapshot: CurrentInputTextSnapshot,
        selectionSnapshot: TextSelectionSnapshot,
        selectionLimit: Int,
    ) -> InputContextSnapshot? {
        guard let selected = normalizedSelectedText(
            selectionSnapshot.selectedText,
            fallback: "",
            limit: selectionLimit,
        ) else {
            return nil
        }

        return InputContextSnapshot(
            appName: inputSnapshot.processName ?? selectionSnapshot.processName,
            bundleIdentifier: inputSnapshot.bundleIdentifier ?? selectionSnapshot.bundleIdentifier,
            role: selectionSnapshot.role ?? inputSnapshot.role,
            isEditable: inputSnapshot.isEditable || selectionSnapshot.isEditable,
            isFocusedTarget: inputSnapshot.isFocusedTarget || selectionSnapshot.isFocusedTarget,
            prefix: "",
            suffix: "",
            selectedText: selected,
        )
    }

    private static func inputContextSkipReason(
        inputSnapshot: CurrentInputTextSnapshot,
        selectionSnapshot: TextSelectionSnapshot,
    ) -> String {
        guard selectionSnapshot.hasSelection else {
            return inputSnapshot.failureReason ?? "missing-input-and-selection-context"
        }
        if !inputSnapshot.isEditable {
            return inputSnapshot.failureReason ?? "focused-element-not-editable"
        }
        guard let text = inputSnapshot.text, !text.isEmpty else {
            return inputSnapshot.failureReason ?? "missing-input-text"
        }
        guard inputSnapshot.selectedRange != nil else {
            return "missing-selected-range"
        }
        return "invalid-selected-range-or-empty-context"
    }

    private static func stringRange(from cfRange: CFRange, in text: String) -> Range<String.Index>? {
        guard cfRange.location >= 0, cfRange.length >= 0 else { return nil }
        guard cfRange.location <= text.count else { return nil }
        guard cfRange.location + cfRange.length <= text.count else { return nil }

        let lowerBound = text.index(text.startIndex, offsetBy: cfRange.location)
        let upperBound = text.index(lowerBound, offsetBy: cfRange.length)
        return lowerBound..<upperBound
    }

    private static func normalizedSelectedText(
        _ selectedText: String?,
        fallback: String,
        limit: Int,
    ) -> String? {
        let candidate = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? selectedText ?? ""
            : fallback
        guard !candidate.isEmpty else { return nil }
        return String(candidate.prefix(limit))
    }
}

private extension String {
    func prefixCharacters(_ limit: Int) -> String {
        guard limit > 0 else { return "" }
        return String(prefix(limit))
    }

    func suffixCharacters(_ limit: Int) -> String {
        guard limit > 0 else { return "" }
        return String(suffix(limit))
    }
}
