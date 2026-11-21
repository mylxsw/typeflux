import SwiftUI

/// Colors visible source rows while leaving prose and unknown files untouched.
struct AskFileSourceStyle {
    let language: AskWorkflowSyntaxHighlighter.Language

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jsx": language = .javascript
        case "tsx", "cts": language = .typescript
        case "jsonl": language = .json
        default:
            let detected = AskWorkflowSyntaxHighlighter.Language.detect(path: path)
            language = detected == .plain && Self.genericExtensions.contains(ext) ? .generic : detected
        }
    }

    private static let genericExtensions: Set<String> = [
        "swift", "go", "rs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs",
        "rb", "php", "dart", "lua", "r", "pl", "scala", "graphql", "proto", "gradle", "css", "scss",
        "less", "vue", "svelte", "html", "htm", "xml", "svg", "yaml", "yml", "toml", "sql", "fish"
    ]

    // swiftlint:disable:next force_try line_length
    private static let genericTokens = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|\b(?:func|let|var|const|return|if|else|import|class|struct|enum|def|for|while|true|false|null|nil)\b|\b\d+(?:\.\d+)?\b"#)

    static func genericLine(_ line: String) -> AttributedString {
        var value = AttributedString(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            value.foregroundColor = .secondary; return value
        }
        for match in genericTokens.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line),
                  let attributedRange = Range(range, in: value) else { continue }
            let token = line[range]
            value[attributedRange].foregroundColor = token.hasPrefix("\"") ? .green : token.first?
                .isNumber == true ? .orange : .purple
        }
        return value
    }
}
