import Foundation

/// Models sometimes join prose and an opening fence ("Replace with```bash").
/// Repair only that line boundary for display; the stored reply stays intact.
enum AskMarkdownFences {
    private static let fence = try! NSRegularExpression(pattern: #"^(?: {0,3}>[ \t]?)* {0,3}(`{3,}|~{3,})(.*)$"#)
    private static let joined = try! NSRegularExpression(pattern: #"^(\S[^`~]*?)(`{3,}|~{3,})([A-Za-z][A-Za-z0-9_+.-]*)[ \t]*$"#)

    static func normalize(_ source: String) -> String {
        var open: (marker: Character, count: Int)?
        return source.components(separatedBy: "\n").map { line in
            let text = line as NSString
            let range = NSRange(location: 0, length: text.length)
            if let match = fence.firstMatch(in: line, range: range) {
                let marker = text.substring(with: match.range(at: 1))
                let suffix = text.substring(with: match.range(at: 2))
                if let current = open {
                    if marker.first == current.marker, marker.count >= current.count,
                       suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                        open = nil
                    }
                } else if marker.first == "~" || !suffix.contains("`") {
                    open = (marker.first!, marker.count)
                }
                return line
            }
            guard open == nil, let match = joined.firstMatch(in: line, range: range) else { return line }
            let marker = text.substring(with: match.range(at: 2))
            open = (marker.first!, marker.count)
            return text.substring(with: match.range(at: 1)) + "\n" + marker
                + text.substring(with: match.range(at: 3))
        }.joined(separator: "\n")
    }
}
