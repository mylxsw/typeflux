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

    var canReplaceSelection: Bool {
        hasAskSelectionContext && (
            isEditable ||
                source == "clipboard-copy"
        )
    }

    var canSafelyRestoreSelection: Bool {
        // Accessibility-backed selections are the only ones we can reliably restore
        // after focus changes. Other editable selections may still be replaceable if
        // they remain active when we send the replacement keystrokes.
        canReplaceSelection && source == "accessibility"
    }
}

struct CurrentInputTextSnapshot {
    var processID: pid_t?
    var processName: String?
    var role: String?
    var text: String?
    var isEditable: Bool = false
    var isFocusedTarget: Bool = false
    var failureReason: String?
}

protocol TextInjector {
    func getSelectionSnapshot() async -> TextSelectionSnapshot
    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot
    func currentInputText() async -> String?
    func insert(text: String) throws
    func replaceSelection(text: String) throws
}
