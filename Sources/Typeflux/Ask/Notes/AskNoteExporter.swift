import AppKit
import Foundation

/// Notes as Markdown files: YAML front matter with where the note came from, then its text.
enum AskNoteExporter {
    static func markdown(_ note: AskNote) -> String {
        var lines = ["---", "title: " + quoted(note.title), "command: " + quoted(note.command)]
        if let model = note.model, !model.isEmpty { lines.append("model: " + quoted(model)) }
        if let app = note.sourceApp, !app.isEmpty { lines.append("source: " + quoted(app)) }
        if !note.tags.isEmpty { lines.append("tags: [" + note.tags.map(quoted).joined(separator: ", ") + "]") }
        lines.append("created: " + timestamp(note.createdAt))
        lines.append("updated: " + timestamp(note.updatedAt))
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + note.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// The title as a file name: no path separators or characters Finder rejects, never empty.
    static func fileName(_ note: AskNote) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = note.title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? L("ask.notes.untitled") : String(cleaned.prefix(80))
        return base + ".md"
    }

    /// A JSON string is valid YAML and escapes everything that needs it.
    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(text), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Puts Markdown on the pasteboard as rich text: HTML and RTF for apps that keep
/// formatting, and the Markdown itself for plain-text fields.
enum AskRichCopy {
    @MainActor
    static func copy(_ markdown: String, to pasteboard: NSPasteboard? = nil) {
        let target = pasteboard ?? AskQuickResults.pasteboard
        target.clearContents()
        target.declareTypes([.html, .rtf, .string], owner: nil)
        target.setString(html(markdown), forType: .html)
        if let rtf = rtf(markdown) { target.setData(rtf, forType: .rtf) }
        target.setString(markdown, forType: .string)
    }

    static func html(_ markdown: String) -> String {
        "<meta charset=\"utf-8\">" + MarkdownHTMLRenderer().render(markdown: markdown)
    }

    @MainActor
    static func rtf(_ markdown: String) -> Data? {
        let text = AskMarkdownText.render(markdown)
        return try? text.data(from: NSRange(location: 0, length: text.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}
