import Foundation

/// A name prepared for matching: its folded bytes, where its words start, and,
/// when it has Chinese characters, how it reads in pinyin. Built once per name.
struct AskSearchKey: Equatable, Sendable {
    var bytes: [UInt8]
    /// Byte offsets of each word's first character; names are matched on their first 255 bytes' words.
    var wordStarts: [UInt8]
    /// Where a file's extension starts (the dot), so "readme" names README.md exactly.
    var extensionStart: Int?
    var pinyin: AskPinyinKey?
    /// The characters of the name and of its pinyin, for `AskSearchText.mask`.
    var mask: UInt64

    init(_ name: String, hasExtension: Bool = false) {
        bytes = AskSearchText.normalize(name)
        wordStarts = AskSearchText.wordStarts(name).compactMap { $0 <= Int(UInt8.max) ? UInt8($0) : nil }
        if hasExtension, let dot = bytes.lastIndex(of: 0x2E), dot > 0, dot < bytes.count - 1 {
            extensionStart = dot
        }
        pinyin = AskSearchText.containsHan(name) ? AskPinyinKey(name) : nil
        mask = AskSearchText.mask(bytes) | (pinyin.map { AskSearchText.mask($0.spelling) } ?? 0)
    }
}

/// How a name with Chinese characters reads: each syllable toneless and without
/// spaces, and which bytes of the folded name it stands for. Latin runs count as
/// one syllable each ("QQ音乐" → qq · yin · yue).
struct AskPinyinKey: Equatable, Sendable {
    struct Syllable: Equatable, Sendable {
        /// Where it starts in `spelling`.
        var offset: Int
        var length: Int
        /// The bytes of the folded name it reads.
        var name: Range<Int>
        var han: Bool
    }

    var spelling: [UInt8] = []
    var syllables: [Syllable] = []

    var initials: [UInt8] { syllables.map { spelling[$0.offset] } }

    init(_ name: String) {
        let characters = Array(name)
        var offset = 0
        var index = 0
        var latin: (start: Int, bytes: [UInt8])?
        func endLatin() {
            guard let run = latin else { return }
            add(run.bytes, name: run.start ..< run.start + run.bytes.count, han: false)
            latin = nil
        }
        while index < characters.count {
            let character = characters[index]
            let folded = AskSearchText.normalize(String(character))
            if character.unicodeScalars.contains(where: AskSearchText.isHan) {
                endLatin()
                let readings = Self.readings(at: index, in: characters)
                for reading in readings {
                    let width = AskSearchText.normalize(String(characters[index])).count
                    add(Array(reading.utf8), name: offset ..< offset + width, han: true)
                    offset += width
                    index += 1
                }
                continue
            }
            if character.isLetter || character.isNumber {
                if latin == nil { latin = (offset, []) }
                latin?.bytes.append(contentsOf: folded)
            } else {
                endLatin()
            }
            offset += folded.count
            index += 1
        }
        endLatin()
    }

    private mutating func add(_ syllable: [UInt8], name: Range<Int>, han: Bool) {
        guard !syllable.isEmpty else { return }
        syllables.append(Syllable(offset: spelling.count, length: syllable.count, name: name, han: han))
        spelling.append(contentsOf: syllable)
    }

    /// The reading of the Han character at `index`, or of a whole known word
    /// starting there whose characters have several readings (银行 is "yin hang").
    private static func readings(at index: Int, in characters: [Character]) -> [String] {
        for (word, reading) in AskAppEntry.readings {
            let wordCharacters = Array(word)
            guard index + wordCharacters.count <= characters.count,
                  Array(characters[index ..< index + wordCharacters.count]) == wordCharacters else { continue }
            let parts = reading.split(separator: " ").map(String.init)
            if parts.count == wordCharacters.count { return parts }
        }
        return [reading(of: characters[index])]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Character: String] = [:]

    /// One character's toneless pinyin, as the system reads it on its own.
    static func reading(of character: Character) -> String {
        if let cached = lock.withLock({ cache[character] }) { return cached }
        let latin = NSMutableString(string: String(character)) as CFMutableString
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
        let reading = (latin as String).lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        lock.withLock { cache[character] = reading }
        return reading
    }
}
