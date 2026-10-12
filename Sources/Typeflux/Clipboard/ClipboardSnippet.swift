import Foundation

/// Metadata on a permanent clipboard text item. Retention never depends on pinning.
struct ClipboardSnippet: Equatable, Sendable {
    var name: String
    var alias: String

    static func normalizedAlias(_ alias: String) -> String {
        alias.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ").lowercased()
    }

    static func validated(name: String, text: String, alias: String) throws -> ClipboardSnippet {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw ClipboardSnippetError.invalidName }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardSnippetError.emptyText
        }
        guard alias.count <= 40 else { throw ClipboardSnippetError.invalidAlias }
        return ClipboardSnippet(name: name, alias: alias)
    }
}

enum ClipboardSnippetError: Error, LocalizedError, Equatable {
    case invalidName, emptyText, invalidAlias, duplicateAlias, missingItem, unavailable

    var errorDescription: String? {
        L("clipboard.snippet.error.\(self)")
    }
}

/// A draft holds the source ID so refreshes or selection changes cannot redirect a save.
struct ClipboardSnippetDraft: Equatable {
    let entry: ClipboardEntry
    var name: String
    var text: String
    var alias: String

    init(entry: ClipboardEntry) {
        self.entry = entry
        name = entry.snippet?
            .name ?? String((entry.text ?? "").components(separatedBy: .newlines).first?.prefix(26) ?? "")
        text = entry.text ?? ""
        alias = entry.snippet?.alias ?? ""
    }
}

/// Only a complete, explicit invocation expands; ordinary dictation is never fuzzy-matched.
enum ClipboardSnippetCommand {
    static func alias(in text: String) -> String? {
        let text = text.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["插入片段", "insert snippet "] where text.lowercased().hasPrefix(prefix) {
            let alias = String(text.dropFirst(prefix.count))
            let normalized = ClipboardSnippet.normalizedAlias(alias)
            return normalized.isEmpty ? nil : normalized
        }
        return nil
    }
}
