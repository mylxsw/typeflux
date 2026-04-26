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
        guard inputSnapshot.isEditable, inputSnapshot.isFocusedTarget else { return nil }
        guard let text = inputSnapshot.text, !text.isEmpty else { return nil }
        guard
            let selectedRange = inputSnapshot.selectedRange,
            let range = stringRange(from: selectedRange, in: text)
        else {
            return nil
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
            isFocusedTarget: inputSnapshot.isFocusedTarget,
            prefix: prefix,
            suffix: suffix,
            selectedText: selected,
        )
        return snapshot.hasContent ? snapshot : nil
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
