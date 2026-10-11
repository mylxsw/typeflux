import Foundation

/// The notes editor's text changes, as pure functions over the text and the selection so
/// they can be tested without a text view. Each returns the range of the old text to
/// replace, the replacement, and the selection afterwards.
enum AskMarkdownFormat: Equatable, CaseIterable {
    case heading1, heading2, heading3, bold, italic, strikethrough, code, link, bulletList, taskList, quote, table

    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    // One exhaustive branch per editor action keeps their shortcut behavior together.
    // swiftlint:disable:next cyclomatic_complexity
    func edit(_ text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let selection = NSRange(location: min(selection.location, string.length),
                                length: min(selection.length, string.length - min(selection.location, string.length)))
        switch self {
        case .bold: return Self.wrap(string, selection, "**")
        case .italic: return Self.wrap(string, selection, "*")
        case .strikethrough: return Self.wrap(string, selection, "~~")
        case .code: return Self.wrap(string, selection, "`")
        case .link:
            let label = string.substring(with: selection)
            let replacement = "[" + label + "](https://)"
            // The URL is selected so typing replaces it; with no label, the label's place.
            let url = NSRange(location: selection.location + (label as NSString).length + 3, length: 8)
            let caret = NSRange(location: selection.location + 1, length: 0)
            return Edit(range: selection, replacement: replacement, selection: label.isEmpty ? caret : url)
        case .heading1: return Self.prefixLines(string, selection, "# ", exclusive: Self.headingPrefixes)
        case .heading2: return Self.prefixLines(string, selection, "## ", exclusive: Self.headingPrefixes)
        case .heading3: return Self.prefixLines(string, selection, "### ", exclusive: Self.headingPrefixes)
        case .bulletList: return Self.prefixLines(string, selection, "- ", exclusive: Self.listPrefixes)
        case .taskList: return Self.prefixLines(string, selection, "- [ ] ", exclusive: Self.listPrefixes)
        case .quote: return Self.prefixLines(string, selection, "> ", exclusive: ["> "])
        case .table:
            let template = "| | |\n|---|---|\n| | |\n"
            let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let atLineStart = selection.location == lineStart
            let lead = atLineStart ? "" : "\n"
            return Edit(range: NSRange(location: NSMaxRange(selection), length: 0), replacement: lead + template,
                        selection: NSRange(location: NSMaxRange(selection) + (lead as NSString).length + 2, length: 0))
        }
    }

    static let headingPrefixes = ["### ", "## ", "# "]
    static let listPrefixes = ["- [ ] ", "- [x] ", "- ", "* ", "+ "]

    /// Surrounds the selection with a marker, or takes it away when the selection already has it.
    private static func wrap(_ string: NSString, _ selection: NSRange, _ marker: String) -> Edit {
        let length = (marker as NSString).length
        let selected = string.substring(with: selection)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= length * 2 {
            let innerRange = NSRange(location: length, length: (selected as NSString).length - length * 2)
            let inner = (selected as NSString).substring(with: innerRange)
            return Edit(range: selection, replacement: inner,
                        selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        // Markers just outside the selection: unwrap them too.
        if selection.location >= length, NSMaxRange(selection) + length <= string.length,
           string.substring(with: NSRange(location: selection.location - length, length: length)) == marker,
           string.substring(with: NSRange(location: NSMaxRange(selection), length: length)) == marker,
           selection.length > 0 {
            let range = NSRange(location: selection.location - length, length: selection.length + length * 2)
            return Edit(range: range, replacement: selected,
                        selection: NSRange(location: selection.location - length, length: selection.length))
        }
        return Edit(range: selection, replacement: marker + selected + marker,
                    selection: NSRange(location: selection.location + length, length: selection.length))
    }

    /// Adds `prefix` to every selected line, replacing another prefix of the same kind;
    /// when every line already has it, takes it away.
    private static func prefixLines(_ string: NSString, _ selection: NSRange, _ prefix: String,
                                    exclusive: [String]) -> Edit {
        let range = string.lineRange(for: selection)
        var block = string.substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { block.removeLast() }
        var lines = block.components(separatedBy: "\n")
        let removing = lines.allSatisfy { $0.hasPrefix(prefix) }
        for index in lines.indices {
            var line = lines[index]
            if let existing = exclusive.first(where: { line.hasPrefix($0) }) { line.removeFirst(existing.count) }
            lines[index] = removing ? line : prefix + line
        }
        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        let caretEnd = range.location + (replacement as NSString).length - (endsWithNewline ? 1 : 0)
        let selectionAfter = selection.length == 0
            ? NSRange(location: caretEnd, length: 0)
            : NSRange(location: range.location, length: caretEnd - range.location)
        return Edit(range: range, replacement: replacement, selection: selectionAfter)
    }

    /// Return inside a list item: the next line starts with the same marker (numbers count
    /// up, tasks start unticked). Return on an empty item ends the list. Nil elsewhere.
    static func newline(_ text: String, at location: Int) -> Edit? {
        let string = text as NSString
        guard location <= string.length else { return nil }
        let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
        let lineStart = lineRange.location
        let line = string.substring(with: NSRange(location: lineStart, length: location - lineStart))
        let pattern = #"^(\s*)([-*+] \[[ xX]\] |[-*+] |(\d+)([.)]) |> )"#
        guard let match = line.range(of: pattern, options: .regularExpression)
        else { return nil }
        let marker = String(line[match])
        let rest = line[match.upperBound...]
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: the marker goes and the list ends.
            let range = NSRange(location: lineStart, length: (line as NSString).length)
            return Edit(range: range, replacement: "", selection: NSRange(location: lineStart, length: 0))
        }
        var next = marker
        if let number = marker.range(of: #"\d+"#, options: .regularExpression), let value = Int(marker[number]) {
            next.replaceSubrange(number, with: String(value + 1))
        }
        next = next.replacingOccurrences(of: "[x] ", with: "[ ] ").replacingOccurrences(of: "[X] ", with: "[ ] ")
        let insertion = "\n" + next
        return Edit(range: NSRange(location: location, length: 0), replacement: insertion,
                    selection: NSRange(location: location + (insertion as NSString).length, length: 0))
    }

    /// Tab and ⇧Tab on list lines: indents or outdents them by two spaces. Nil elsewhere.
    static func indent(_ text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let string = text as NSString
        let range = string.lineRange(for: selection)
        var block = string.substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { block.removeLast() }
        var lines = block.components(separatedBy: "\n")
        let pattern = #"^\s*([-*+] |\d+[.)] )"#
        guard lines.contains(where: { $0.range(of: pattern, options: .regularExpression) != nil }) else { return nil }
        var shift = 0
        for index in lines.indices where lines[index].range(of: pattern, options: .regularExpression) != nil {
            if outdent {
                let spaces = min(2, lines[index].prefix { $0 == " " }.count)
                lines[index].removeFirst(spaces)
                if index == 0 { shift = -spaces }
            } else {
                lines[index] = "  " + lines[index]
                if index == 0 { shift = 2 }
            }
        }
        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        let delta = (replacement as NSString).length - range.length
        let start = max(range.location, selection.location + shift)
        let length = max(0, selection.length + delta - (start - selection.location))
        return Edit(range: range, replacement: replacement,
                    selection: NSRange(location: start, length: length))
    }
}

/// Colours for Markdown source: where markers, headings, emphasis and code are.
enum AskMarkdownHighlighter {
    enum Kind: Equatable {
        case marker, heading, strong, emphasis, code, fence, link, quote
    }

    struct Span: Equatable {
        var range: NSRange
        var kind: Kind
    }

    private struct InlineRule {
        var pattern: String
        var kind: Kind
        var markerLength: Int
    }

    static func spans(_ text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        var fence = AskNoteFenceState()
        var location = 0
        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = lineRange
            while contentRange.length > 0,
                  [10, 13].contains(string.character(at: NSMaxRange(contentRange) - 1)) { contentRange.length -= 1 }
            let line = string.substring(with: contentRange)
            location = NSMaxRange(lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence.consumeDelimiter(line) {
                spans.append(Span(range: contentRange, kind: .fence))
                continue
            }
            if fence.isOpen {
                if contentRange.length > 0 { spans.append(Span(range: contentRange, kind: .code)) }
                continue
            }
            if let heading = AskNoteHeading.heading(trimmed) {
                let hashes = (line as NSString).range(of: String(repeating: "#", count: heading.level))
                let markerLength = NSMaxRange(hashes) + 1
                spans.append(Span(range: NSRange(location: contentRange.location,
                                                length: min(markerLength, contentRange.length)),
                                  kind: .marker))
                spans.append(Span(range: NSRange(location: contentRange.location + markerLength,
                                                 length: max(0, contentRange.length - markerLength)), kind: .heading))
                continue
            }
            if trimmed.hasPrefix(">") {
                spans.append(Span(range: contentRange, kind: .quote))
            }
            if trimmed.hasPrefix("|") {
                spans.append(Span(range: contentRange, kind: .marker))
                continue
            }
            if let marker = line.range(of: #"^\s*([-*+] (\[[ xX]\] )?|\d+[.)] |> ?)"#, options: .regularExpression) {
                let range = NSRange(marker, in: line)
                spans.append(Span(range: NSRange(location: contentRange.location + range.location,
                                                length: range.length),
                                  kind: .marker))
            }
            spans.append(contentsOf: inlineSpans(line, at: contentRange.location))
        }
        return spans
    }

    private static func inlineSpans(_ line: String, at location: Int) -> [Span] {
        var spans: [Span] = []
        let lineRange = NSRange(location: 0, length: (line as NSString).length)
        let rules = [
            InlineRule(pattern: #"\*\*[^*\n]+\*\*"#, kind: .strong, markerLength: 2),
            InlineRule(pattern: #"~~[^~\n]+~~"#, kind: .strong, markerLength: 2),
            InlineRule(pattern: #"(?<![*\w])\*[^*\s][^*\n]*\*(?!\*)"#, kind: .emphasis, markerLength: 1),
            InlineRule(pattern: #"`[^`\n]+`"#, kind: .code, markerLength: 1)
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let markerLength = rule.markerLength
            for match in regex.matches(in: line, range: lineRange) {
                let range = NSRange(location: location + match.range.location, length: match.range.length)
                spans.append(Span(range: NSRange(location: range.location, length: markerLength), kind: .marker))
                spans.append(Span(range: NSRange(location: range.location + markerLength,
                                                 length: range.length - markerLength * 2), kind: rule.kind))
                spans.append(Span(range: NSRange(location: NSMaxRange(range) - markerLength, length: markerLength),
                                  kind: .marker))
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#) {
            for match in regex.matches(in: line, range: lineRange) {
                spans.append(Span(range: NSRange(location: location + match.range.location,
                                                 length: match.range.length), kind: .link))
            }
        }
        return spans
    }
}
