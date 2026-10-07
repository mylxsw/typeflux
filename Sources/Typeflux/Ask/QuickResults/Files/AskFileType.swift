import Foundation

/// The kinds of files the file mode can be narrowed to, by extension.
enum AskFileType: String, CaseIterable, Sendable {
    case all
    case folder
    case document
    case image
    case pdf
    case sheet
    case code

    static let extensions: [AskFileType: Set<String>] = [
        .document: ["doc", "docx", "pages", "txt", "rtf", "rtfd", "md", "markdown", "odt", "epub", "tex", "wps"],
        .image: ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef",
                 "psd", "sketch", "fig", "ico", "icns"],
        .pdf: ["pdf"],
        .sheet: ["xls", "xlsx", "numbers", "csv", "tsv", "key", "ppt", "pptx", "odp", "ods"],
        .code: ["swift", "m", "h", "c", "cc", "cpp", "hpp", "go", "py", "js", "jsx", "ts", "tsx", "rs", "java", "kt",
                "rb", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "xml", "html", "css", "scss", "sql", "dart",
                "lua", "proto", "gradle", "vue", "svelte"]
    ]

    var title: String { L("ask.search.type.\(rawValue)") }

    /// Whether an entry of `kind` with extension `ext` (lowercased, may be empty) is of this type.
    func matches(kind: AskFileRecord.Kind, extension ext: String) -> Bool {
        switch self {
        case .all: return true
        case .folder: return kind == .folder
        default: return kind != .folder && Self.extensions[self]?.contains(ext) == true
        }
    }

    /// The type after (or before) this one, for ⇥ and ⇧⇥.
    func next(_ step: Int) -> AskFileType {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[((index + step) % all.count + all.count) % all.count]
    }

    /// Shows pictures and PDFs as thumbnails rather than icons.
    static func hasThumbnail(_ ext: String) -> Bool {
        ext == "pdf" || (extensions[.image]?.contains(ext) == true && ext != "svg" && ext != "fig" && ext != "sketch")
    }
}
