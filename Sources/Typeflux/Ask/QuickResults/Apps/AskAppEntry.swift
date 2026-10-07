import Foundation

/// One application the launcher can open, with every name it answers to and
/// the keys those names are matched by. Built once per scan, off the main thread.
struct AskAppEntry: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case application
        /// A pane of System Settings, such as Network; it opens with `settingsURL`.
        case settingsPane
    }

    /// The name shown in the list: the one Finder shows on this Mac.
    var name: String
    var url: URL
    var bundleID: String?
    var kind: Kind = .application
    /// Lowercased names in every language found: Finder's, the bundle's own,
    /// its Chinese name and the file name.
    var names: [String]
    /// Per name: the first letter of each word ("visual studio code" → "vsc").
    var initials: [String]
    /// Han names spelled in pinyin without spaces ("微信" → "weixin").
    var pinyin: [String]
    /// Han names by the first letter of each syllable ("微信" → "wx").
    var pinyinInitials: [String]
    /// Every name prepared for `AskFuzzyMatcher`; the first is `name`, whose matches are highlighted.
    var keys: [AskSearchKey]

    var id: String { bundleID ?? url.path }

    /// Where a settings pane opens: `x-apple.systempreferences:` with its identifier.
    var settingsURL: URL? {
        guard kind == .settingsPane, let bundleID else { return nil }
        return URL(string: "x-apple.systempreferences:" + bundleID)
    }

    init(name: String, url: URL, bundleID: String?, names: [String], kind: Kind = .application) {
        self.name = name
        self.url = url
        self.bundleID = bundleID
        self.kind = kind
        var seen = Set<String>()
        let trimmed = ([name] + names)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        keys = trimmed.map { AskSearchKey($0) }
        let lowered = trimmed.map { $0.lowercased() }
        self.names = lowered
        initials = Self.unique(([name] + names).compactMap { Self.initials(of: $0) })
        let han = lowered.filter(Self.containsHan)
        let syllables = han.map(Self.pinyinSyllables)
        pinyin = Self.unique(syllables.map { $0.joined() })
        pinyinInitials = Self.unique(syllables.map { String($0.compactMap(\.first)) })
    }

    /// Splits on spaces, punctuation and lower-to-upper case changes, so
    /// "TablePlus" and "Visual Studio Code" both get initials. Single words have none.
    static func initials(of name: String) -> String? {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for char in name {
            if char.isWhitespace || "-_.·&+".contains(char) {
                if !current.isEmpty { words.append(current); current = "" }
            } else if char.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                words.append(current); current = String(char)
            } else {
                current.append(char)
            }
            previous = char
        }
        if !current.isEmpty { words.append(current) }
        guard words.count > 1 else { return nil }
        return String(words.compactMap { $0.first?.lowercased().first })
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) || (0x3400 ... 0x4DBF).contains($0.value) }
    }

    /// Words common in app names whose characters have several readings. The
    /// system transform reads character by character, so 音乐 would become
    /// "yin le" and 银行 "yin xing".
    static let readings: [String: String] = [
        "音乐": " yin yue ", "银行": " yin hang ", "行情": " hang qing ", "重庆": " chong qing ",
        "长沙": " chang sha ", "朝阳": " chao yang ", "便签": " bian qian ", "觉醒": " jue xing "
    ]

    /// "QQ音乐" → ["qq", "yin", "yue"]: Han characters become toneless pinyin
    /// syllables; other runs stay as they are.
    static func pinyinSyllables(_ text: String) -> [String] {
        var source = text
        for (word, reading) in readings where source.contains(word) {
            source = source.replacingOccurrences(of: word, with: reading)
        }
        let latin = NSMutableString(string: source) as CFMutableString
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
        return (latin as String).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// An application found for the launcher's text, best first.
struct AskAppMatch: Equatable, Sendable {
    var entry: AskAppEntry
    var score: Double
    /// Characters of `entry.name` that matched, for bold; empty when another of its names did.
    var highlights: [Range<Int>] = []
}
