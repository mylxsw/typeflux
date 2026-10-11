import Foundation

/// Tracks matching Markdown fences, including tildes and longer outer fences.
struct AskNoteFenceState {
    private var marker: Character?
    private var count = 0
    var isOpen: Bool { marker != nil }

    /// Returns true only for an opening or matching closing delimiter.
    mutating func consumeDelimiter(_ line: String) -> Bool {
        let indentation = line.prefix { $0 == " " }.count
        guard indentation <= 3 else { return false }
        let content = line.dropFirst(indentation)
        guard let character = content.first, character == "`" || character == "~" else { return false }
        let length = content.prefix { $0 == character }.count
        guard length >= 3 else { return false }
        let suffix = content.dropFirst(length)
        if let marker {
            guard character == marker, length >= count,
                  suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            self.marker = nil
        } else {
            guard character == "~" || !suffix.contains("`") else { return false }
            marker = character
            count = length
        }
        return true
    }
}

/// A `#`, `##` or `###` heading of a note, for the outline and for reading one section.
struct AskNoteHeading: Equatable, Sendable, Identifiable {
    var level: Int
    var text: String
    /// The heading's line, counted from zero.
    var line: Int
    var id: Int { line }

    /// Headings outside fenced code blocks.
    static func parse(_ markdown: String) -> [AskNoteHeading] {
        var result: [AskNoteHeading] = []
        var fence = AskNoteFenceState()
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if fence.consumeDelimiter(raw) { continue }
            guard !fence.isOpen, raw.prefix(4) != "    ", !raw.hasPrefix("\t"),
                  let heading = heading(line) else { continue }
            result.append(AskNoteHeading(level: heading.level, text: heading.text, line: index))
        }
        return result
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1 ... 3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    /// The lines from a heading (matched by its text, ignoring case) up to the next heading
    /// at the same or a higher level; nil when no heading has that text.
    static func section(_ markdown: String, heading name: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        let wanted = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces).lowercased()
        let headings = parse(markdown)
        guard let start = headings.firstIndex(where: { $0.text.lowercased() == wanted }) else { return nil }
        let first = headings[start]
        let end = headings[(start + 1)...].first { $0.level <= first.level }?.line ?? lines.count
        return lines[first.line ..< end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text with `addition` at the end of the named section, or at the end of the note
    /// when there is no such heading.
    static func appending(_ addition: String, to markdown: String, under name: String?) -> String {
        let block = addition.trimmingCharacters(in: .newlines)
        guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        if let name, !name.isEmpty {
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            let headings = parse(markdown)
            if let start = headings.firstIndex(where: { $0.text.lowercased() == wanted }) {
                var end = headings[(start + 1)...].first { $0.level <= headings[start].level }?.line ?? lines.count
                while end > headings[start].line + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    end -= 1
                }
                // A blank line before the next heading, unless one is already there.
                let needsGap = end < lines.count && !lines[end].trimmingCharacters(in: .whitespaces).isEmpty
                let insertion = ["", block] + (needsGap ? [""] : [])
                lines.insert(contentsOf: insertion, at: end)
                return lines.joined(separator: "\n")
            }
        }
        let trimmed = markdown.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? block : trimmed + "\n\n" + block
    }
}

/// Task list items (`- [ ]`, `- [x]`) outside code blocks.
enum AskNoteTasks {
    struct Task: Equatable {
        var line: Int
        var done: Bool
        var text: String
    }

    private static let pattern = #"^(\s*[-*+]\s+)\[( |x|X)\](\s+|$)"#

    static func taskLines(_ markdown: String) -> [Task] {
        var result: [Task] = []
        var fence = AskNoteFenceState()
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            if fence.consumeDelimiter(line) { continue }
            guard !fence.isOpen, let match = line.range(of: pattern, options: .regularExpression) else { continue }
            let marker = line[match]
            let done = marker.contains("[x]") || marker.contains("[X]")
            result.append(Task(line: index, done: done,
                               text: String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// Flips the `index`th task, changing only its box; nil when there is no such task.
    static func toggling(_ markdown: String, task index: Int) -> String? {
        let tasks = taskLines(markdown)
        guard tasks.indices.contains(index) else { return nil }
        var lines = markdown.components(separatedBy: "\n")
        let task = tasks[index]
        var line = lines[task.line]
        guard let range = line.range(of: task.done ? "[x]" : "[ ]", options: task.done ? .caseInsensitive : [])
        else { return nil }
        line.replaceSubrange(range, with: task.done ? "[ ]" : "[x]")
        lines[task.line] = line
        return lines.joined(separator: "\n")
    }

    /// Task boxes as ☐ and ☑ for display, so the renderer draws them as text; the order
    /// matches `taskLines`.
    static func displayText(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        for task in taskLines(markdown) {
            var line = lines[task.line]
            if let range = line.range(of: pattern, options: .regularExpression) {
                let prefix = line[range].prefix { $0 != "[" }
                line.replaceSubrange(range, with: prefix + (task.done ? "☑\u{FE0E} " : "☐\u{FE0E} "))
            }
            lines[task.line] = line
        }
        return lines.joined(separator: "\n")
    }
}

/// YAML front matter as `AskNoteExporter` writes it: `key: value` lines between `---`.
enum AskNoteFrontMatter {
    /// The fields and the text after them; no fields when the text has no front matter.
    static func split(_ text: String) -> (fields: [String: String], body: String) {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], normalized) }
        var fields: [String: String] = [:]
        for line in lines[1 ..< end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        guard !fields.isEmpty else { return ([:], normalized) }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (fields, body)
    }

    /// A scalar without its quotes; JSON-style escapes in double quotes are decoded.
    static func scalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2,
           let data = trimmed.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }

    /// `[a, "b"]` or `a, b` as a list.
    static func list(_ value: String) -> [String] {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) { return decoded }
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { trimmed = String(trimmed.dropFirst().dropLast()) }
        return splitList(trimmed)
    }

    /// Splits YAML-style scalars without treating commas inside quotes as separators.
    private static func splitList(_ text: String) -> [String] {
        var values: [String] = []
        var part = ""
        var quote: Character?
        var escaped = false
        var doubledQuote = false
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if doubledQuote {
                doubledQuote = false
            } else if escaped {
                escaped = false
            } else if quote == "\"", character == "\\" {
                escaped = true
            } else if let current = quote {
                if current == "'", character == "'", index + 1 < characters.count, characters[index + 1] == "'" {
                    doubledQuote = true
                } else if character == current {
                    quote = nil
                }
            } else if character == "\"" || character == "'", part.trimmingCharacters(in: .whitespaces).isEmpty {
                quote = character
            } else if character == "," {
                values.append(scalar(part))
                part = ""
                continue
            }
            part.append(character)
        }
        values.append(scalar(part))
        return values.filter { !$0.isEmpty }
    }

    static func date(_ value: String) -> Date? {
        let text = scalar(value)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }
}
