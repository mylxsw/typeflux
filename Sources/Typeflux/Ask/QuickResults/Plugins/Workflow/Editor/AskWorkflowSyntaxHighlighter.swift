import Foundation

/// Colors for the editor's code view: comments, strings, keywords, numbers and
/// calls, by regular expressions per language. Not a parser; good enough to read
/// a workflow script, and fast enough to run on every edit of a visible range.
struct AskWorkflowSyntaxHighlighter: Sendable {
    enum Language: String, CaseIterable, Sendable {
        case python, javascript, typescript, shell, applescript, json, plain

        /// From the file's extension, then the runtime that runs it.
        static func detect(path: String, runtime: AskWorkflowRuntime? = nil) -> Language {
            let fileExtension = (path as NSString).pathExtension.lowercased()
            guard fileExtension.isEmpty else { return extensions[fileExtension] ?? .plain }
            return detect(runtime: runtime)
        }

        private static let extensions: [String: Language] = [
            "py": .python, "js": .javascript, "mjs": .javascript, "cjs": .javascript, "ts": .typescript,
            "mts": .typescript, "sh": .shell, "zsh": .shell, "bash": .shell, "applescript": .applescript,
            "scpt": .applescript, "json": .json
        ]

        private static func detect(runtime: AskWorkflowRuntime?) -> Language {
            switch runtime {
            case .python3: .python
            case .node: .javascript
            case .typescript: .typescript
            case .zsh, .bash: .shell
            case .osascript: .applescript
            default: .plain
            }
        }
    }

    enum Token: String, Sendable {
        case comment, string, keyword, number, call, key
    }

    struct Span: Equatable, Sendable {
        var range: NSRange
        var token: Token
    }

    /// Files this long are only colored where they are visible.
    static let fullHighlightLimit = 256_000

    let language: Language

    /// Spans inside `range` (all of `text` by default), in order, never overlapping:
    /// a keyword inside a string or comment is not colored as a keyword.
    func spans(in text: String, range: NSRange? = nil) -> [Span] {
        let content = text as NSString
        let limit = range ?? NSRange(location: 0, length: content.length)
        guard limit.length > 0, language != .plain else { return [] }
        var spans: [Span] = []
        var covered = IndexSet()
        for (pattern, token) in rules {
            for match in pattern.matches(in: text, range: limit) {
                let target = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? match.range(at: 1) : match.range
                guard target.length > 0 else { continue }
                let indexes = IndexSet(integersIn: target.location ..< target.location + target.length)
                guard !covered.intersects(integersIn: target.location ..< target.location + target.length)
                else { continue }
                covered.formUnion(indexes)
                spans.append(Span(range: target, token: token))
            }
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// Strings and comments first: whatever they cover is not looked at again.
    private var rules: [(NSRegularExpression, Token)] {
        Self.compiled[language] ?? []
    }

    private static let compiled: [Language: [(NSRegularExpression, Token)]] = {
        func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // The patterns are constants; a typo is a programming error caught by the tests.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        func words(_ list: String) -> NSRegularExpression {
            rx("\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b")
        }
        let number = rx(#"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
        let call = rx(#"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?=\()"#)
        let python: [(NSRegularExpression, Token)] = [
            (rx(#"(?s)(?:[rRbBfFuU]{0,2})(?:\"\"\".*?\"\"\"|'''.*?''')"#), .string),
            (rx(#"#[^\n]*"#), .comment),
            (rx(#"(?:[rRbBfFuU]{0,2})(?:"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#), .string),
            (
                words(
                    "False None True and as assert async await break class continue def del elif else "
                        + "except finally for from global if import in is lambda nonlocal not or pass raise "
                        + "return try while with yield"
                ),
                .keyword
            ),
            (number, .number), (call, .call)
        ]
        let script: [(NSRegularExpression, Token)] = [
            (rx(#"(?s)/\*.*?\*/"#), .comment),
            (rx(#"//[^\n]*"#), .comment),
            (rx(#"(?s)`(?:\\.|[^`\\])*`"#), .string),
            (rx(#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#), .string),
            (
                words(
                    "async await break case catch class const continue default delete do else export "
                        + "extends false finally for from function if import in instanceof let new null of "
                        + "return static super switch this throw true try typeof undefined var void while "
                        + "yield interface type enum implements readonly as"
                ),
                .keyword
            ),
            (number, .number), (call, .call)
        ]
        let shell: [(NSRegularExpression, Token)] = [
            (rx(#"(?m)(?:^|(?<=\s))#[^\n]*"#), .comment),
            (rx(#""(?:\\.|[^"\\])*"|'[^']*'"#), .string),
            (
                words(
                    "if then else elif fi for while until do done case esac in function return local "
                        + "export readonly print echo exit set unset shift"
                ),
                .keyword
            ),
            (rx(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@*#?]"#), .call),
            (number, .number)
        ]
        let applescript: [(NSRegularExpression, Token)] = [
            (rx(#"(?s)\(\*.*?\*\)"#), .comment),
            (rx(#"(?:--|#)[^\n]*"#), .comment),
            (rx(#""(?:\\.|[^"\\\n])*""#), .string),
            (
                words(
                    "on end tell to set if then else repeat return of the with without try error my "
                        + "get copy run script property global local exit considering ignoring"
                ),
                .keyword
            ),
            (number, .number)
        ]
        let json: [(NSRegularExpression, Token)] = [
            (rx(#"("(?:\\.|[^"\\\n])*")\s*:"#), .key),
            (rx(#""(?:\\.|[^"\\\n])*""#), .string),
            (words("true false null"), .keyword),
            (rx(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#), .number)
        ]
        return [.python: python, .javascript: script, .typescript: script, .shell: shell,
                .applescript: applescript, .json: json]
    }()
}
