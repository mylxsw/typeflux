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

protocol TextInjector {
    func getSelectionSnapshot() async -> TextSelectionSnapshot
    func insert(text: String) throws
    func replaceSelection(text: String) throws
}
