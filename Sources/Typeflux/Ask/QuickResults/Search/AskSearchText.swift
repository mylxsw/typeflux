import Foundation

/// How names and queries are compared: lowercased, without accents or full-width
/// forms, as UTF-8 bytes. Matching runs on bytes so a search over hundreds of
/// thousands of file names allocates nothing per name.
enum AskSearchText {
    /// The folded form of `text`. Each character folds on its own, so a position in
    /// the result can always be traced back to the character it came from.
    static func normalize(_ text: String) -> [UInt8] {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for character in text { bytes.append(contentsOf: fold(character)) }
        return bytes
    }

    /// The folded bytes with, for each byte, the index of the character in `text` it came from.
    static func normalizeWithMap(_ text: String) -> (bytes: [UInt8], characters: [Int]) {
        var bytes: [UInt8] = []
        var characters: [Int] = []
        for (index, character) in text.enumerated() {
            let folded = fold(character)
            bytes.append(contentsOf: folded)
            characters.append(contentsOf: repeatElement(index, count: folded.count))
        }
        return (bytes, characters)
    }

    /// Byte ranges of a folded name as ranges of characters in the name it came from.
    static func characterRanges(_ ranges: [Range<Int>], in text: String) -> [Range<Int>] {
        let map = normalizeWithMap(text).characters
        var result: [Range<Int>] = []
        for range in ranges where range.lowerBound < map.count && !range.isEmpty {
            let lower = map[range.lowerBound]
            let upper = map[min(range.upperBound, map.count) - 1] + 1
            if let last = result.last, last.upperBound >= lower {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, upper)
            } else {
                result.append(lower ..< upper)
            }
        }
        return result
    }

    private static let foldLock = NSLock()
    nonisolated(unsafe) private static var foldCache: [Character: [UInt8]] = [:]

    private static func fold(_ character: Character) -> [UInt8] {
        if let ascii = character.asciiValue {
            return [ascii >= 0x41 && ascii <= 0x5A ? ascii | 0x20 : ascii]
        }
        if let cached = foldLock.withLock({ foldCache[character] }) { return cached }
        let folded = Array(String(character)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
        let bytes = folded.isEmpty ? Array(String(character).utf8) : folded
        foldLock.withLock { foldCache[character] = bytes }
        return bytes
    }

    // MARK: - Words

    /// Where each word of `name` starts, as byte offsets into its folded form: after
    /// spaces and punctuation, and where a lowercase letter meets an uppercase one
    /// ("TablePlus", "Visual Studio Code", "final_cut-pro").
    static func wordStarts(_ name: String) -> [Int] {
        var starts: [Int] = []
        var offset = 0
        var previous: Character?
        var inWord = false
        for character in name {
            let separator = isSeparator(character)
            if separator {
                inWord = false
            } else if !inWord {
                starts.append(offset)
                inWord = true
            } else if character.isUppercase, let previous, previous.isLowercase {
                starts.append(offset)
            }
            previous = character
            offset += fold(character).count
        }
        return starts
    }

    static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    // MARK: - Prefilter

    /// Which characters `bytes` contains, as 64 buckets: one per ASCII letter and
    /// digit, the rest shared. A name can only match a query whose mask it covers.
    static func mask<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var mask: UInt64 = 0
        for byte in bytes { mask |= bit(byte) }
        return mask
    }

    @inline(__always) static func bit(_ byte: UInt8) -> UInt64 {
        switch byte {
        case 0x61 ... 0x7A: return 1 << UInt64(byte - 0x61)
        case 0x30 ... 0x39: return 1 << UInt64(26 + byte - 0x30)
        case 0x20, 0x09: return 0
        default: return 1 << UInt64(36 + Int(byte) % 28)
        }
    }

    // MARK: - Han

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHan)
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00 ... 0x9FFF).contains(scalar.value) || (0x3400 ... 0x4DBF).contains(scalar.value)
    }
}
