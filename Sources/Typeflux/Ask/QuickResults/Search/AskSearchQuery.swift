import Foundation

/// What was typed, ready for matching: the words folded, plus the filters a file
/// search understands (`.pdf` or `ext:pdf` for a type, `in:design` for a folder).
struct AskSearchQuery: Equatable, Sendable {
    /// Queries longer than this are sentences for the AI, not names.
    static let maximumLength = 40

    /// The words, folded, without spaces.
    var words: [[UInt8]]
    /// All the words run together: what an application name is matched against.
    var compact: [UInt8]
    /// A file extension, lowercased, without the dot.
    var fileExtension: String?
    /// Part of the name of a folder the file must be in, folded.
    var folder: [UInt8]?
    var text: String

    init(_ text: String) {
        self.text = text
        var words: [[UInt8]] = []
        var fileExtension: String?
        var folder: [UInt8]?
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(raw)
            let lowered = word.lowercased()
            if lowered.hasPrefix("ext:"), lowered.count > 4 {
                fileExtension = String(lowered.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else if lowered.hasPrefix("in:"), lowered.count > 3 {
                folder = AskSearchText.normalize(String(word.dropFirst(3)))
            } else if lowered.hasPrefix("."), (2 ... 8).contains(lowered.count),
                      lowered.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                fileExtension = String(lowered.dropFirst())
            } else {
                // Punctuation only changes whether a question takes Return, not what it finds.
                let folded = AskSearchText.normalize(word.filter { !$0.isPunctuation || $0 == "." || $0 == "-" || $0 == "_" })
                if !folded.isEmpty { words.append(folded) }
            }
        }
        self.words = words
        self.fileExtension = fileExtension?.isEmpty == true ? nil : fileExtension
        self.folder = folder?.isEmpty == true ? nil : folder
        compact = Array(words.joined())
    }

    var isEmpty: Bool { words.isEmpty && fileExtension == nil && folder == nil }
    var hasFilters: Bool { fileExtension != nil || folder != nil }

    /// Whether this could name something: short, one line, and with words.
    var isSearchable: Bool {
        text.count <= Self.maximumLength && !text.contains(where: \.isNewline) && !compact.isEmpty
    }

    /// For a name's mask to cover.
    var mask: UInt64 { AskSearchText.mask(compact) }
}
