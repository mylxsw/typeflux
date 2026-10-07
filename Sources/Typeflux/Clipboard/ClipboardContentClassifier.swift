import Foundation
import UniformTypeIdentifiers

/// Derives what a clipboard payload looks like to the user.
enum ClipboardContentClassifier {
    static func kind(forText text: String) -> ClipboardEntryKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLink(trimmed) { return .link }
        if looksLikeCode(trimmed) { return .code }
        return .text
    }

    static func kind(forFilePaths paths: [String]) -> ClipboardEntryKind {
        let kinds = paths.map(kind(forFilePath:))
        guard let first = kinds.first else { return .files }
        if kinds.count == 1 { return first }
        return kinds.allSatisfy { $0 == .image } ? .images : .files
    }

    static func kind(forFilePath path: String) -> ClipboardEntryKind {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .document }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .document
    }

    /// A short uppercase badge for document types, e.g. `PDF`, `DOCX`.
    static func badge(forFilePath path: String) -> String {
        let ext = (path as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }

    static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https"].contains(scheme) && url.host?.isEmpty == false
    }

    /// A conservative heuristic: several lines with code punctuation or keywords.
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return false }
        let markers = [
            "{", "}", "();", "=>", "->", "func ", "def ", "class ", "import ", "return ", "const ", "let ", "var "
        ]
        let hits = lines.filter { line in markers.contains { line.contains($0) } }.count
        return hits * 2 >= lines.count
    }
}
