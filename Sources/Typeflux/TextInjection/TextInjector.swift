import Foundation

struct TextSelectionSnapshot {
    var processID: pid_t?
    var processName: String?
    var selectedRange: CFRange?
    var selectedText: String?
    var source: String = "none"
    var isEditable: Bool = false
    var role: String?
    var windowTitle: String?
    var isFocusedTarget: Bool = false

    var hasSelection: Bool {
        let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    var hasAskSelectionContext: Bool {
        isFocusedTarget && hasSelection
    }

    var canSafelyReplaceSelection: Bool {
        // Only treat Accessibility-backed selections as replaceable. Clipboard-derived
        // selections prove that text is selected, but not that the target is a writable
        // input field or that we can restore the exact range safely.
        hasAskSelectionContext && isEditable && source == "accessibility"
    }
}

struct CurrentInputTextSnapshot {
    var processID: pid_t?
    var processName: String?
    var role: String?
    var text: String?
    var isEditable: Bool = false
    var failureReason: String?
}

protocol TextInjector {
    func getSelectionSnapshot() async -> TextSelectionSnapshot
    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot
    func currentInputText() async -> String?
    func insert(text: String) throws
    func replaceSelection(text: String) throws
}
