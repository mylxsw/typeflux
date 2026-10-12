import Foundation

struct EmojiMatch: Equatable, Sendable {
    var entry: EmojiEntry
    var score: Int
    var reason: String
}

/// All indexing and matching stay off the main actor; UI receives value snapshots.
actor EmojiSearchService {
    static let shared = EmojiSearchService()
    private let load: @Sendable () throws -> EmojiCatalog
    private let supported: @Sendable (String) -> Bool
    private var entries: [EmojiEntry]?
    private var terms: [String: [Int: Int]] = [:]
    private var sequences: [String: Int] = [:]
    private var spellingTerms: [Int: [String]] = [:]
    private var renderingSupport: [String: Bool] = [:]

    init(load: @escaping @Sendable () throws -> EmojiCatalog = { try EmojiCatalog.load() },
         supported: @escaping @Sendable (String) -> Bool = { EmojiCatalog.supports($0) }) {
        self.load = load
        self.supported = supported
    }

    static func emojiKey(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0E && $0.value != 0xFE0F }))
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
            .replacingOccurrences(of: "_", with: " ")
    }

    private func prepare() throws -> [EmojiEntry] {
        if let entries {
            return entries
        }
        let loaded = try load().entries
        var index: [String: [Int: Int]] = [:]
        var sequenceIndex: [String: Int] = [:]
        for (offset, entry) in loaded.enumerated() {
            try Task.checkCancellation()
            sequenceIndex[entry.sequence] = offset
            sequenceIndex[Self.emojiKey(entry.sequence)] = offset
            entry.variants
                .forEach { sequenceIndex[$0.sequence] = offset; sequenceIndex[Self.emojiKey($0.sequence)] = offset }
            func add(_ term: String, _ score: Int) {
                let term = Self.normalize(term)
                guard !term.isEmpty else { return }
                index[term, default: [:]][offset] = max(score, index[term]?[offset] ?? 0)
            }
            for name in entry.names.values {
                add(name, 110)
            }
            for keyword in entry.keywords {
                add(keyword, 100)
                for word in Self.normalize(keyword).split(separator: " ") {
                    add(String(word), 100)
                }
                if entry.pinyin == nil, keyword.count <= 6, AskSearchText.containsHan(keyword) {
                    let pinyin = AskPinyinKey(keyword)
                    add(String(bytes: pinyin.spelling, encoding: .utf8) ?? "", 95)
                    if pinyin.initials.count > 1 {
                        add(String(bytes: pinyin.initials, encoding: .utf8) ?? "", 88)
                    }
                }
            }
            for spelling in entry.pinyin ?? [] {
                add(spelling, 95)
            }
        }
        terms = index
        spellingTerms = Dictionary(
            grouping: index.keys.filter { $0.utf8.allSatisfy { (97 ... 122).contains($0) } },
            by: { $0.utf8.count }
        )
        sequences = sequenceIndex
        entries = loaded
        return loaded
    }

    func search(_ text: String, scope: EmojiScope = .all, usage: EmojiUsage = EmojiUsage(),
                limit: Int = 80) throws -> [EmojiMatch] {
        guard text.count <= 160, limit > 0 else { return [] }
        let entries = try prepare()
        try Task.checkCancellation()
        let query = Self.normalize(text)
        var matches: [Int: (Int, String)] = [:]
        if query.isEmpty {
            for index in entries.indices {
                matches[index] = (0, "browse")
            }
        } else if let exact = sequences[Self.emojiKey(query)] {
            let entry = entries[exact]
            let sequence = entry.variants.first { Self.emojiKey($0.sequence) == Self.emojiKey(query) }?
                .sequence ?? entry.sequence
            guard canRender(sequence) else { return [] }
            matches[exact] = (120, "exact")
        } else if let intent = EmojiIntents.match(query) {
            for (position, emoji) in intent.enumerated() {
                if let index = sequences[emoji] {
                    matches[index] = (105, "intent:\(position)")
                }
            }
        } else {
            matches = try lexicalMatches(query)
        }
        boostExactPhrase(query, matches: &matches)
        return try rank(matches, entries: entries, scope: scope, usage: usage, limit: limit)
    }

    private func boostExactPhrase(_ query: String, matches: inout [Int: (Int, String)]) {
        guard !query.isEmpty, let exactPhrase = terms[query] else { return }
        for (index, score) in exactPhrase where score >= 110 || matches[index] != nil {
            if score > (matches[index]?.0 ?? -1) {
                matches[index] = (score, "keyword")
            }
        }
    }

    private func rank(_ matches: [Int: (Int, String)], entries: [EmojiEntry], scope: EmojiScope,
                      usage: EmojiUsage, limit: Int) throws -> [EmojiMatch] {
        let recents = Dictionary(
            usage.recent.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranked = matches.compactMap { index, value -> EmojiMatch? in
            let entry = entries[index]
            guard scope != .favorites || usage.favorites.contains(entry.id),
                  scope != .recent || recents[entry.id] != nil else { return nil }
            return EmojiMatch(entry: entry, score: value.0, reason: value.1)
        }.sorted { left, right in
            if left.score != right.score {
                return left.score > right.score
            }
            if left.reason.hasPrefix("intent:"), right.reason.hasPrefix("intent:") {
                return left.reason < right.reason
            }
            let leftRecent = recents[left.entry.id] ?? Int.max, rightRecent = recents[right.entry.id] ?? Int.max
            if leftRecent != rightRecent {
                return leftRecent < rightRecent
            }
            return (sequences[left.entry.sequence] ?? 0) < (sequences[right.entry.sequence] ?? 0)
        }
        var results: [EmojiMatch] = []
        for var match in ranked {
            try Task.checkCancellation()
            guard canRender(match.entry.sequence) else { continue }
            match.entry.variants = match.entry.variants.filter { canRender($0.sequence) }
            results.append(match)
            if results.count >= min(limit, 200) {
                break
            }
        }
        return results
    }

    private func canRender(_ sequence: String) -> Bool {
        if let cached = renderingSupport[sequence] {
            return cached
        }
        let available = supported(sequence)
        renderingSupport[sequence] = available
        return available
    }

    private func wordMatches(_ word: String) throws -> [Int: (Int, String)] {
        if let exact = terms[word], exact.count >= 3 {
            return exact.mapValues { ($0, "keyword") }
        }
        var found: [Int: (Int, String)] = [:]
        func merge(_ hits: [Int: Int], score: Int, reason: String) {
            for (index, weight) in hits {
                let value = min(weight, score)
                if value > (found[index]?.0 ?? -1) {
                    found[index] = (value, reason)
                }
            }
        }
        if let exact = terms[word] {
            merge(exact, score: 110, reason: "keyword")
        }
        for (term, hits) in terms {
            if term == word {
                continue
            }
            if term.hasPrefix(word) {
                merge(hits, score: 80, reason: "prefix")
            } else if word.count >= 2, term.contains(word) {
                merge(hits, score: 60, reason: "contains")
            }
        }
        if found.count < 3, word.count >= 4, word.utf8.allSatisfy({ (97 ... 122).contains($0) }) {
            let threshold = word.count >= 8 ? 2 : 1
            for length in (word.utf8.count - threshold) ... (word.utf8.count + threshold) {
                for term in spellingTerms[length] ?? [] {
                    try Task.checkCancellation()
                    if Self.distance(word, term, limit: threshold) <= threshold, let hits = terms[term] {
                        merge(hits, score: 40, reason: "typo:\(word) → \(term)")
                    }
                }
            }
        }
        return found
    }

    private func lexicalMatches(_ query: String) throws -> [Int: (Int, String)] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Keep unrecognised negation intact instead of turning it into a positive emotion.
        if words.contains(where: { ["not", "don't", "dont", "never", "no"].contains($0) }) {
            return [:]
        }
        var matches: [Int: (Int, String)] = [:]
        for (wordIndex, word) in words.enumerated() {
            let found = try wordMatches(word)
            if wordIndex == 0 {
                matches = found
            } else {
                for (index, old) in matches {
                    guard let new = found[index] else { matches.removeValue(forKey: index); continue }
                    matches[index] = old.0 <= new.0 ? old : new
                }
            }
            if matches.isEmpty {
                break
            }
        }
        return matches
    }

    /// Bounded optimal-string-alignment distance, including adjacent transpositions.
    static func distance(_ left: String, _ right: String, limit: Int) -> Int {
        let leftBytes = Array(left.utf8), rightBytes = Array(right.utf8)
        guard abs(leftBytes.count - rightBytes.count) <= limit else { return limit + 1 }
        if leftBytes.isEmpty {
            return rightBytes.count
        }
        if rightBytes.isEmpty {
            return leftBytes.count
        }
        var previous = Array(0 ... rightBytes.count), before = previous
        for row in 1 ... leftBytes.count {
            var current = [row] + Array(repeating: 0, count: rightBytes.count)
            for column in 1 ... rightBytes.count {
                current[column] = min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + (leftBytes[row - 1] == rightBytes[column - 1] ? 0 : 1)
                )
                if row > 1, column > 1, leftBytes[row - 1] == rightBytes[column - 2],
                   leftBytes[row - 2] == rightBytes[column - 1] {
                    current[column] = min(
                        current[column],
                        before[column - 2] + 1
                    )
                }
            }
            if current.min()! > limit {
                return limit + 1
            }
            before = previous
            previous = current
        }
        return previous[rightBytes.count]
    }
}

/// Reviewed complete expressions; no stop-word removal that discards negation.
enum EmojiIntents {
    static let groups: [([String], [String])] = [
        (
            [
                "感谢",
                "感謝",
                "ganxie",
                "gx",
                "想表达感谢",
                "表达感谢",
                "感谢帮助",
                "谢谢你帮我",
                "谢谢帮忙",
                "辛苦了",
                "感謝幫助",
                "想表達感謝",
                "thank you for your help",
                "thanks for helping"
            ],
            ["🙏", "🥹", "💐", "🫶", "🤝"]
        ),
        (
            ["不想上班", "上班好累", "累到不想说话", "心累", "撑不住了", "累到不想說話", "too tired to work", "exhausted from work"],
            ["😮‍💨", "🫠", "😴", "🙃"]
        ),
        (["生日快乐", "生日快樂", "祝你生日快乐", "happy birthday"], ["🎂", "🎉", "🥳", "🎁"]),
        (["恭喜上线", "终于上线了", "发布成功", "庆祝成功", "恭喜上線", "發布成功", "launch success", "we shipped it"], ["🎉", "🚀", "🙌", "👏"]),
        (["不开心", "不開心", "不高兴", "不高興", "not happy", "feeling down"], ["😢", "😭", "😮‍💨"]),
        (["太好笑了", "笑死我了", "笑不活了", "can't stop laughing", "so funny"], ["😂", "🤣", "😆"]),
        (["不知道说什么", "不知道說什麼", "无话可说", "無話可說", "no words", "speechless"], ["😶", "😑", "🫠"]),
        (["想你了", "好想你", "miss you", "thinking of you"], ["🥺", "❤️", "😘"]),
        (["需要抱抱", "安慰一下", "need a hug", "sending hugs"], ["🤗", "🫂", "❤️"]),
        (["祝你好运", "祝你好運", "good luck", "fingers crossed"], ["🤞", "🍀", "🙏"]),
        (["为你加油", "為你加油", "you can do it", "keep going"], ["💪", "🙌", "🔥"]),
        (["我同意", "说得对", "說得對", "i agree", "well said"], ["👍", "💯", "✅"]),
        (["太尴尬了", "太尷尬了", "so awkward", "awkward moment"], ["😅", "😬", "🫠"]),
        (["工作完成", "终于搞定", "終於搞定", "all done", "job done"], ["✅", "🎉", "😌"]),
        (["哭泣"], ["😢", "😭"]),
        (["戴单片眼镜的脸", "戴單片眼鏡的臉"], ["🧐"]),
        (["有点生气", "有點生氣", "气死我了", "氣死我了", "so angry", "really annoyed"], ["😠", "😤", "🤬"]),
        (["想睡觉", "想睡覺", "困死了", "need sleep", "so sleepy"], ["😴", "🥱", "💤"]),
        (["吓我一跳", "嚇我一跳", "太震惊了", "太震驚了", "what a surprise", "so shocked"], ["😲", "😱", "🤯"]),
        (["休息一下", "喝杯咖啡", "coffee break", "take a break"], ["☕", "😌", "🛋️"]),
        (["周末快乐", "週末快樂", "happy weekend", "time to relax"], ["🥳", "😎", "🍻"]),
        (["新年快乐", "新年快樂", "happy new year"], ["🎆", "🎉", "🧧"])
    ]
    static func match(_ query: String) -> [String]? {
        groups.first { $0.0.contains(query) }?.1
    }
}
