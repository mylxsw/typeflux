import AppKit
import Foundation

/// How a file tab shows a file.
enum AskSidePanelFileKind: Equatable, Sendable {
    case html, markdown, csv, image, pdf, text, unsupported

    private static let textExtensions: Set<String> = [
        "txt", "log", "json", "jsonl", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "env",
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "kts", "c", "h",
        "cc", "cpp", "hpp", "m", "mm", "cs", "rb", "php", "sh", "bash", "zsh", "fish", "sql", "css", "scss",
        "less", "vue", "svelte", "dart", "lua", "r", "pl", "scala", "graphql", "proto", "gradle", "make",
        "dockerfile", "gitignore", "diff", "patch", "tex", "srt", "vtt", "svg"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico"
    ]

    /// Decided by the extension; files without a known one are text when their bytes are.
    static func kind(forExtension raw: String, sample: Data? = nil) -> AskSidePanelFileKind {
        let ext = raw.lowercased()
        switch ext {
        case "html", "htm": return .html
        case "md", "markdown", "mdown": return .markdown
        case "csv", "tsv": return .csv
        case "pdf": return .pdf
        default: break
        }
        if imageExtensions.contains(ext) { return .image }
        if textExtensions.contains(ext) { return .text }
        if let sample, looksLikeText(sample) { return .text }
        return .unsupported
    }

    /// UTF-8 without NUL bytes in the first few kilobytes.
    static func looksLikeText(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        guard !head.contains(0) else { return false }
        if String(data: head, encoding: .utf8) != nil { return true }
        // The sample may cut a multi-byte character; drop up to three trailing bytes.
        for cut in 1 ... 3 where head.count > cut {
            if String(data: head.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// HTML, Markdown and CSV can show their source instead of the rendered preview.
    var hasSource: Bool { [.html, .markdown, .csv].contains(self) }
}

/// What a file tab shows once loaded.
enum AskSidePanelFileContent {
    case html(AskArtifactBundle, source: String)
    case markdown(String, truncated: Bool)
    case csv(AskCSVTable, source: String)
    case image(NSImage)
    case pdf(Data)
    case text(String, truncated: Bool)
    case unsupported
    case failure(String)
}

enum AskSidePanelFileLoader {
    static let textLimit = 2 * 1024 * 1024
    static let csvRowLimit = 500
    static let imageLimit = 64 * 1024 * 1024
    static let pdfLimit = 200 * 1024 * 1024

    /// Reads through the access check, never through a plain file URL.
    static func load(_ target: AskSidePanelFileAccess.Target, kind: AskSidePanelFileKind,
                     roots: [String]) -> AskSidePanelFileContent {
        do {
            switch kind {
            case .html:
                let bundle = try AskFileHTMLPreview.bundle(target, roots: roots)
                return .html(bundle, source: text(bundle.files[bundle.manifest.entry]!))
            case .markdown:
                let (body, truncated) = try clippedText(target, roots: roots)
                return .markdown(body, truncated: truncated)
            case .csv:
                let (body, _) = try clippedText(target, roots: roots)
                let delimiter: Character = target.name.lowercased().hasSuffix(".tsv") ? "\t" : ","
                return .csv(AskCSVTable.parse(body, delimiter: delimiter, maxRows: csvRowLimit), source: body)
            case .image:
                let data = try AskSidePanelFileAccess.read(target, roots: roots, limit: imageLimit)
                guard let image = NSImage(data: data) else { return .unsupported }
                return .image(image)
            case .pdf:
                return .pdf(try AskSidePanelFileAccess.read(target, roots: roots, limit: pdfLimit))
            case .text:
                let (body, truncated) = try clippedText(target, roots: roots)
                return .text(body, truncated: truncated)
            case .unsupported:
                try AskSidePanelFileAccess.check(target, roots: roots)
                return .unsupported
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Text files show their first `textLimit` bytes rather than refusing a large log.
    private static func clippedText(_ target: AskSidePanelFileAccess.Target,
                                    roots: [String]) throws -> (String, Bool) {
        let (data, clipped) = try AskSidePanelFileAccess.read(target, roots: roots, limit: textLimit, clip: true)
        return (text(data), clipped)
    }

    /// Invalid UTF-8, including a character cut at the clip, shows as replacement characters.
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// The first rows of a CSV or TSV file.
struct AskCSVTable: Equatable {
    static let columnLimit = 64
    let rows: [[String]]
    /// More rows follow the ones parsed.
    let truncated: Bool

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// RFC 4180 quoting: quoted fields may hold delimiters, quotes (`""`) and line breaks.
    static func parse(_ text: String, delimiter: Character = ",", maxRows: Int) -> AskCSVTable {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            if row.count < columnLimit { row.append(field) }
            field = ""
            atFieldStart = true
        }
        func endRow() -> Bool {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
            return rows.count < maxRows
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where atFieldStart:
                quoted = true
                atFieldStart = false
            case delimiter:
                endField()
            case "\n", "\r\n", "\r":
                guard endRow() else {
                    return AskCSVTable(rows: rows, truncated: iterator.next() != nil)
                }
            default:
                field.append(character)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { _ = endRow() }
        return AskCSVTable(rows: rows, truncated: false)
    }
}
