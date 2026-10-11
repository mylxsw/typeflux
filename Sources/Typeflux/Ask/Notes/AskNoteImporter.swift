import Foundation

/// Markdown and text files dropped on the notes window, or chosen with Import, as notes.
/// Front matter written by `AskNoteExporter` (or another app) keeps its title, tags and dates.
enum AskNoteImporter {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "txt", "text"]
    static let maximumBytes = 1_000_000
    static let maximumFiles = 200

    struct Result: Equatable {
        var notes: [AskNote] = []
        /// Files left out: too large, not text, or past the limit.
        var skipped: [String] = []
    }

    static func canImport(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func notes(from urls: [URL], now: Date = Date()) -> Result {
        var result = Result()
        for (index, url) in urls.enumerated() {
            guard index < maximumFiles else { result.skipped.append(url.lastPathComponent); continue }
            guard canImport(url),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumBytes,
                  let data = try? Data(contentsOf: url), data.count <= maximumBytes,
                  let text = String(data: data, encoding: .utf8)
            else { result.skipped.append(url.lastPathComponent); continue }
            result.notes.append(note(text, fileName: url.deletingPathExtension().lastPathComponent, now: now))
        }
        return result
    }

    /// One file's text as a note: the front matter's title, else the first heading, else the file name.
    static func note(_ text: String, fileName: String, now: Date = Date()) -> AskNote {
        let (fields, body) = AskNoteFrontMatter.split(text)
        let title = fields["title"].map(AskNoteFrontMatter.scalar).flatMap { $0.isEmpty ? nil : $0 }
            ?? AskNoteHeading.parse(body).first?.text
            ?? (fileName.isEmpty ? L("ask.notes.untitled") : fileName)
        let tags = fields["tags"].map(AskNoteFrontMatter.list)?.compactMap(AskNote.normalizedTag) ?? []
        let created = fields["created"].flatMap(AskNoteFrontMatter.date) ?? now
        let updated = fields["updated"].flatMap(AskNoteFrontMatter.date) ?? created
        var unique: [String] = []
        for tag in tags where !unique.contains(tag) { unique.append(tag) }
        return AskNote(title: String(title.prefix(200)), body: body,
                       command: fields["command"].map(AskNoteFrontMatter.scalar) ?? "", keyword: "", input: "",
                       model: fields["model"].map(AskNoteFrontMatter.scalar), tags: unique, createdAt: created,
                       updatedAt: max(updated, created), source: .import)
    }
}
