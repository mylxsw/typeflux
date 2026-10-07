import Foundation

/// How well a name answers a query, and which bytes of its folded form matched.
struct AskFuzzyMatch: Equatable, Sendable {
    var score: Double
    /// Byte ranges of the folded name; empty when only its pinyin initials or a path matched nothing visible.
    var ranges: [Range<Int>] = []
}

/// Scores one name against what was typed. Applications and files share it, so
/// `wx` finds 微信 and `ht` finds 采购合同 the same way in both. The rules, best first:
///
/// | Match | Score | Example |
/// |---|---|---|
/// | the whole name (a file's without its extension too) | 1.0 | `wechat`, `readme` → README.md |
/// | its whole pinyin | 0.95 | `weixin` → 微信 |
/// | the start of the name | 0.9 | `calc` |
/// | its initials, or its pinyin initials | 0.88 | `vsc`, `wx` |
/// | the start of its pinyin | 0.86 | `weix` |
/// | the start of a word | 0.82 | `studio` |
/// | the start of its initials | 0.8 | `vs` |
/// | pinyin from a later character on, spelled or by initials | 0.7 / 0.66 | `hetong`, `ht` → 采购合同 |
/// | anywhere in the name | 0.6 | `hat` → WeChat |
/// | its letters in order, closer together scoring higher | 0.45–0.55 | `tbpls` → TablePlus |
///
/// Spaces in the name are skipped, so `visualstudio` matches "Visual Studio".
enum AskFuzzyMatcher {
    static let exact = 1.0
    static let pinyinExact = 0.95
    static let prefix = 0.9
    static let initials = 0.88
    static let pinyinPrefix = 0.86
    static let wordPrefix = 0.82
    static let initialsPrefix = 0.8
    static let pinyinLater = 0.7
    static let pinyinInitialsLater = 0.66
    static let contains = 0.6
    static let inOrder = 0.45

    /// The best match of `query` (folded, without spaces) in a name, or nil.
    /// `fuzzy` allows letters in order; `ranges` asks for the matched bytes.
    static func match(_ query: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>,
                      wordStarts: UnsafeBufferPointer<UInt8>, extensionStart: Int? = nil,
                      pinyin: AskPinyinKey? = nil, fuzzy: Bool = true, ranges wantRanges: Bool = false) -> AskFuzzyMatch? {
        let count = query.count
        guard count > 0, !name.isEmpty else { return nil }
        var positions: [Int] = []
        func result(_ score: Double) -> AskFuzzyMatch {
            AskFuzzyMatch(score: score, ranges: wantRanges ? Self.ranges(positions) : [])
        }
        func resultRange(_ score: Double, _ range: Range<Int>) -> AskFuzzyMatch {
            AskFuzzyMatch(score: score, ranges: wantRanges ? [range] : [])
        }

        // The whole name, or a file's name without its extension.
        if matchFlat(query, in: name, at: 0, end: name.count, whole: true, positions: &positions, record: wantRanges) {
            return result(exact)
        }
        if let extensionStart,
           matchFlat(query, in: name, at: 0, end: extensionStart, whole: true, positions: &positions, record: wantRanges) {
            return result(exact)
        }
        let letters = count >= 2 && query.allSatisfy { $0 < 0x80 }
        if letters, let pinyin, let found = pinyinMatch(query, pinyin, whole: true) {
            return resultRange(pinyinExact, found)
        }
        if matchFlat(query, in: name, at: 0, end: name.count, whole: false, positions: &positions, record: wantRanges) {
            return result(prefix)
        }
        let hasInitials = wordStarts.count >= 2
        if letters, hasInitials, initialsMatch(query, name: name, starts: wordStarts, whole: true) {
            return AskFuzzyMatch(score: initials, ranges: wantRanges ? initialRanges(count, name, wordStarts) : [])
        }
        if letters, let pinyin, pinyin.syllables.count == count, pinyinInitialsMatch(query, pinyin, from: 0) {
            return resultRange(initials, pinyinRange(pinyin, from: 0, syllables: count))
        }
        if letters, let pinyin, let found = pinyinMatch(query, pinyin, whole: false) {
            return resultRange(pinyinPrefix, found)
        }
        for start in wordStarts where start > 0 {
            if matchFlat(query, in: name, at: Int(start), end: name.count, whole: false, positions: &positions,
                         record: wantRanges) {
                return result(wordPrefix)
            }
        }
        if letters, hasInitials, initialsMatch(query, name: name, starts: wordStarts, whole: false) {
            return AskFuzzyMatch(score: initialsPrefix, ranges: wantRanges ? initialRanges(count, name, wordStarts) : [])
        }
        if letters, let pinyin, pinyin.syllables.count > count, pinyinInitialsMatch(query, pinyin, from: 0) {
            return resultRange(initialsPrefix, pinyinRange(pinyin, from: 0, syllables: count))
        }
        if letters, let pinyin {
            if let found = pinyinLaterMatch(query, pinyin) { return resultRange(pinyinLater, found) }
            for index in pinyin.syllables.indices.dropFirst() where pinyin.syllables[index].han
                && index + count <= pinyin.syllables.count && pinyinInitialsMatch(query, pinyin, from: index) {
                return resultRange(pinyinInitialsLater, pinyinRange(pinyin, from: index, syllables: count))
            }
        }
        if count >= 2 {
            for start in 1 ..< name.count where !AskSearchText.isSpace(name[start]) && name[start] == query[0] {
                if matchFlat(query, in: name, at: start, end: name.count, whole: false, positions: &positions,
                             record: wantRanges) {
                    return result(contains)
                }
            }
        }
        if fuzzy, count >= 3, query.allSatisfy({ $0 < 0x80 }), let span = inOrderSpan(query, name, &positions, record: wantRanges) {
            return result(inOrder + 0.1 * Double(count) / Double(max(span, count)))
        }
        return nil
    }

    /// Convenience for a prepared key and a query string, as the launcher's app list uses.
    static func match(_ query: [UInt8], _ key: AskSearchKey, fuzzy: Bool = true, ranges: Bool = false) -> AskFuzzyMatch? {
        query.withUnsafeBufferPointer { query in
            key.bytes.withUnsafeBufferPointer { name in
                key.wordStarts.withUnsafeBufferPointer { starts in
                    match(query, name: name, wordStarts: starts, extensionStart: key.extensionStart,
                          pinyin: key.pinyin, fuzzy: fuzzy, ranges: ranges)
                }
            }
        }
    }

    // MARK: - Pieces

    /// Whether `query` matches `name` from `start`, skipping spaces in the name:
    /// all the way to `end` when `whole`, else as a prefix.
    private static func matchFlat(_ query: UnsafeBufferPointer<UInt8>, in name: UnsafeBufferPointer<UInt8>,
                                  at start: Int, end: Int, whole: Bool, positions: inout [Int], record: Bool) -> Bool {
        if record { positions.removeAll(keepingCapacity: true) }
        var index = start
        for byte in query {
            while index < end, AskSearchText.isSpace(name[index]) { index += 1 }
            guard index < end, name[index] == byte else { return false }
            if record { positions.append(index) }
            index += 1
        }
        if whole {
            while index < end, AskSearchText.isSpace(name[index]) { index += 1 }
            return index == end
        }
        return true
    }

    /// The first letters of the words: all of them (`whole`) or the first few.
    private static func initialsMatch(_ query: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>,
                                      starts: UnsafeBufferPointer<UInt8>, whole: Bool) -> Bool {
        guard whole ? starts.count == query.count : starts.count > query.count else { return false }
        for (offset, byte) in query.enumerated() where Int(starts[offset]) >= name.count || name[Int(starts[offset])] != byte {
            return false
        }
        return true
    }

    private static func initialRanges(_ count: Int, _ name: UnsafeBufferPointer<UInt8>,
                                      _ starts: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        starts.prefix(count).map { Int($0) ..< Int($0) + 1 }
    }

    /// The whole pinyin, or its start; the name bytes of the syllables it covers.
    private static func pinyinMatch(_ query: UnsafeBufferPointer<UInt8>, _ pinyin: AskPinyinKey, whole: Bool) -> Range<Int>? {
        guard whole ? pinyin.spelling.count == query.count : pinyin.spelling.count > query.count,
              spells(query, pinyin, from: 0) else { return nil }
        return coveredRange(pinyin, from: 0, length: query.count)
    }

    /// The spelling from a later Chinese character on: `hetong` in 采购合同.
    private static func pinyinLaterMatch(_ query: UnsafeBufferPointer<UInt8>, _ pinyin: AskPinyinKey) -> Range<Int>? {
        for syllable in pinyin.syllables.dropFirst() where syllable.han
            && syllable.offset + query.count <= pinyin.spelling.count && spells(query, pinyin, from: syllable.offset) {
            // At least the first syllable must be spelled out, so `h` alone does not read as 合.
            guard query.count >= min(syllable.length, 2) else { continue }
            return coveredRange(pinyin, from: syllable.offset, length: query.count)
        }
        return nil
    }

    private static func spells(_ query: UnsafeBufferPointer<UInt8>, _ pinyin: AskPinyinKey, from offset: Int) -> Bool {
        guard offset + query.count <= pinyin.spelling.count else { return false }
        for (index, byte) in query.enumerated() where pinyin.spelling[offset + index] != byte { return false }
        return true
    }

    private static func pinyinInitialsMatch(_ query: UnsafeBufferPointer<UInt8>, _ pinyin: AskPinyinKey, from index: Int) -> Bool {
        guard index + query.count <= pinyin.syllables.count else { return false }
        for (offset, byte) in query.enumerated() where pinyin.spelling[pinyin.syllables[index + offset].offset] != byte {
            return false
        }
        return true
    }

    /// The name bytes read by the syllables that spelling bytes `from ..< from + length` fall in.
    private static func coveredRange(_ pinyin: AskPinyinKey, from: Int, length: Int) -> Range<Int> {
        let end = from + length
        let covered = pinyin.syllables.filter { $0.offset < end && $0.offset + $0.length > from }
        guard let first = covered.first, let last = covered.last else { return 0 ..< 0 }
        return first.name.lowerBound ..< last.name.upperBound
    }

    private static func pinyinRange(_ pinyin: AskPinyinKey, from index: Int, syllables count: Int) -> Range<Int> {
        let first = pinyin.syllables[index], last = pinyin.syllables[index + count - 1]
        return first.name.lowerBound ..< last.name.upperBound
    }

    /// The letters in order, each as early as possible; the span they cover, in bytes.
    private static func inOrderSpan(_ query: UnsafeBufferPointer<UInt8>, _ name: UnsafeBufferPointer<UInt8>,
                                    _ positions: inout [Int], record: Bool) -> Int? {
        positions.removeAll(keepingCapacity: true)
        var next = 0
        var first = 0
        for (index, byte) in name.enumerated() where byte == query[next] {
            if next == 0 { first = index }
            if record { positions.append(index) }
            next += 1
            if next == query.count { return index - first + 1 }
        }
        return nil
    }

    /// Matched byte positions as runs.
    private static func ranges(_ positions: [Int]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for position in positions {
            if let last = result.last, last.upperBound == position {
                result[result.count - 1] = last.lowerBound ..< position + 1
            } else {
                result.append(position ..< position + 1)
            }
        }
        return result
    }
}
