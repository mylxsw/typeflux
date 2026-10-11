import AppKit
import Foundation

/// Notes as files: Markdown with YAML front matter for where the note came from, a
/// standalone HTML page, or a PDF; one note or a folder of them.
enum AskNoteExporter {
    enum Format: String, CaseIterable, Sendable {
        case markdown = "md", html, pdf
    }

    /// What goes into an exported file besides the text.
    struct Options: Equatable, Sendable {
        /// YAML front matter (Markdown) or a header line (HTML, PDF) with where the note came from.
        var frontMatter = true
        /// The input or question the note answered, quoted before the text.
        var original = false
    }

    static func markdown(_ note: AskNote, options: Options = Options()) -> String {
        let body = text(note, options: options)
        guard options.frontMatter else { return body + "\n" }
        var lines = ["---", "title: " + quoted(note.title)]
        if !note.command.isEmpty { lines.append("command: " + quoted(note.command)) }
        // AI command results keep the first release's fields; other notes say where they came from.
        if note.source != .command { lines.append("from: " + note.source.rawValue) }
        if let model = note.model, !model.isEmpty { lines.append("model: " + quoted(model)) }
        if let app = note.sourceApp, !app.isEmpty { lines.append("source: " + quoted(app)) }
        if !note.tags.isEmpty { lines.append("tags: [" + note.tags.map(quoted).joined(separator: ", ") + "]") }
        lines.append("created: " + timestamp(note.createdAt))
        lines.append("updated: " + timestamp(note.updatedAt))
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    /// The note's text, after its quoted input when `options.original` asks for it.
    static func text(_ note: AskNote, options: Options) -> String {
        // Leading indentation and trailing spaces can be meaningful Markdown.
        let body = note.body.trimmingCharacters(in: .newlines)
        let input = note.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard options.original, !input.isEmpty else { return body }
        let quote = input.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return quote + "\n\n" + body
    }

    /// A page that opens anywhere: the rendered text with its own light/dark styles.
    static func html(_ note: AskNote, options: Options = Options()) -> String {
        let title = escape(note.title)
        var header = ""
        if options.frontMatter {
            var parts = [note.command.isEmpty ? note.source.title : note.command]
            if let app = note.sourceApp, !app.isEmpty { parts.append(app) }
            parts.append(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
            if !note.tags.isEmpty { parts.append(note.tags.map { "#" + $0 }.joined(separator: " ")) }
            header = "<p class=\"meta\">" + escape(parts.joined(separator: " · ")) + "</p>"
        }
        let body = MarkdownHTMLRenderer().render(markdown: text(note, options: options))
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.7 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
          max-width: 720px; margin: 48px auto; padding: 0 24px; }
        h1 { font-size: 28px; line-height: 1.25; margin-bottom: 4px; }
        .meta { color: #888; font-size: 13px; margin-top: 0; }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
        pre { padding: 12px 14px; border-radius: 8px; overflow: auto; background: rgba(127,127,127,.12); }
        code { background: rgba(127,127,127,.12); padding: 1px 4px; border-radius: 4px; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding-left: 14px; border-left: 3px solid rgba(127,127,127,.4); color: #777; }
        table { border-collapse: collapse; } th, td { border: 1px solid rgba(127,127,127,.3); padding: 6px 10px; }
        </style></head>
        <body><h1>\(title)</h1>\(header)
        \(body)
        </body></html>

        """
    }

    /// A paginated A4 PDF of the rendered note, with its title.
    @MainActor
    static func pdf(_ note: AskNote, options: Options = Options()) -> Data? {
        let page = NSSize(width: 595, height: 842)
        let margin: CGFloat = 54
        let content = NSMutableAttributedString(
            string: note.title + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black]
        )
        if options.frontMatter {
            let meta = [note.command.isEmpty ? note.source.title : note.command,
                        note.updatedAt.formatted(date: .abbreviated, time: .shortened)].joined(separator: " · ")
            content.append(NSAttributedString(string: meta + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.gray
            ]))
        }
        let body = NSMutableAttributedString(attributedString: AskMarkdownText.render(text(note, options: options)))
        // Printed on white whatever the appearance: dynamic colours are fixed to their light values.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
                body.enumerateAttribute(key, in: NSRange(location: 0, length: body.length)) { value, range, _ in
                    if let color = value as? NSColor, let fixed = color.usingColorSpace(.sRGB) {
                        body.addAttribute(key, value: fixed, range: range)
                    } else if value == nil, key == .foregroundColor {
                        body.addAttribute(key, value: NSColor.black, range: range)
                    }
                }
            }
        }
        content.append(body)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: page.width - margin * 2, height: page.height))
        view.textStorage?.setAttributedString(content)
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.sizeToFit()
        let info = NSPrintInfo()
        info.paperSize = page
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let data = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run() ? data as Data : nil
    }

    /// The file contents for a format; nil when a PDF could not be drawn.
    @MainActor
    static func data(_ note: AskNote, format: Format, options: Options = Options()) -> Data? {
        switch format {
        case .markdown: markdown(note, options: options).data(using: .utf8)
        case .html: html(note, options: options).data(using: .utf8)
        case .pdf: pdf(note, options: options)
        }
    }

    /// Writes each note as a Markdown file into a new dated folder inside `directory`;
    /// returns the folder. Names that repeat get " 2", " 3".
    @discardableResult
    static func exportFolder(_ notes: [AskNote], into directory: URL, date: Date = Date(),
                             options: Options = Options()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let folderName = L("ask.notes.exportFolder", formatter.string(from: date))
        let folder = uniqueURL(directory.appendingPathComponent(folderName))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        for note in notes {
            let name = uniqueName(fileName(note), used: &used)
            try markdown(note, options: options).write(to: folder.appendingPathComponent(name), atomically: true,
                                                       encoding: .utf8)
        }
        return folder
    }

    /// Notes one after another, as Markdown separated by rules, for copying several at once.
    static func merged(_ notes: [AskNote]) -> String {
        notes.map { "# " + $0.title + "\n\n" + $0.body.trimmingCharacters(in: .newlines) }
            .joined(separator: "\n\n---\n\n")
    }

    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while used.contains(candidate.lowercased()) {
            candidate = base + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            number += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + " \(number)")
            number += 1
        }
        return candidate
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The title as a file name: no path separators or characters Finder rejects, never empty.
    static func fileName(_ note: AskNote, format: Format = .markdown) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = note.title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var base = String(cleaned.prefix(80))
        // File systems limit component bytes, while a Swift Character may span many bytes.
        while base.utf8.count > 240 { base.removeLast() }
        if base.isEmpty { base = L("ask.notes.untitled") }
        return base + "." + format.rawValue
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
