import Foundation

struct TextSelectionSnapshot {
    var processID: pid_t?
    var processName: String?
    var selectedRange: CFRange?
    var selectedText: String?
    var source: String = "none"
    var isEditable: Bool = false

    var hasSelection: Bool {
        let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
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
