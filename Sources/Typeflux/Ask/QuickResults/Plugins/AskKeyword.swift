import Foundation

/// A word the user types at the start of the launcher to reach a plugin, with
/// options it presets: `fy` → translate, `fyja` → translate into Japanese.
struct AskKeyword: Codable, Equatable, Hashable, Identifiable, Sendable {
    var keyword: String
    var pluginID: String
    var options: [String: String] = [:]
    var enabled = true
    var aliases: [String] = []

    /// The first word remains the default used by chips, history and actions.
    var allKeywords: [String] {
        [keyword] + aliases
    }

    func contains(_ word: String) -> Bool {
        allKeywords.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    private enum CodingKeys: String, CodingKey { case keyword, pluginID, options, enabled, aliases }

    init(keyword: String, pluginID: String, options: [String: String] = [:], enabled: Bool = true,
         aliases: [String] = []) {
        self.keyword = keyword
        self.pluginID = pluginID
        self.options = options
        self.enabled = enabled
        self.aliases = aliases
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyword = try values.decode(String.self, forKey: .keyword)
        pluginID = try values.decode(String.self, forKey: .pluginID)
        options = try values.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    var id: String {
        keyword.lowercased()
    }
}

/// Finds a keyword at the start of the launcher's text.
enum AskKeywordMatcher {
    enum Match: Equatable {
        /// The keyword and a separator were typed; what follows is the argument.
        case active(AskKeyword, argument: String)
        /// Only the keyword was typed: offer it, but leave Return alone.
        case hint(AskKeyword)
    }

    /// What may follow a keyword: a space (also full-width) or a colon.
    static let separators: Set<Character> = [" ", "\u{3000}", ":", "："]

    /// The longest enabled keyword the text starts with, followed by a separator
    /// (so `fyi` does not reach `fy`), or the keyword alone as a hint.
    static func match(_ text: String, keywords: [AskKeyword]) -> Match? {
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        let candidates = keywords.filter(\.enabled).flatMap { keyword in
            keyword.allKeywords.map { (word: $0, keyword: keyword) }
        }.sorted { $0.word.count > $1.word.count }
        for candidate in candidates {
            let word = candidate.word.lowercased()
            guard !word.isEmpty, lowered.hasPrefix(word) else { continue }
            let rest = text.dropFirst(word.count)
            guard let first = rest.first else { return .hint(candidate.keyword) }
            guard separators.contains(first) else { continue }
            let argument = rest.dropFirst().drop(while: { $0 == " " || $0 == "\u{3000}" })
            return .active(candidate.keyword, argument: String(argument))
        }
        return nil
    }

    enum Problem: Equatable {
        case empty, tooLong, whitespace, slash, duplicate
    }

    static let maximumLength = 48

    /// Why `keyword` cannot be saved beside `others`, or nil when it can. Two
    /// keywords where one starts the other are fine: the separator decides.
    static func problem(with keyword: String, among others: [AskKeyword]) -> Problem? {
        let word = keyword.trimmingCharacters(in: .whitespaces)
        if word.isEmpty { return .empty }
        if word.count > maximumLength { return .tooLong }
        if word.contains(where: { $0.isWhitespace || separators.contains($0) }) { return .whitespace }
        if word.hasPrefix("/") { return .slash }
        if others.contains(where: { $0.contains(word) }) { return .duplicate }
        return nil
    }
}

/// Converts legacy rows with identical behavior into one editable entry.
/// Different options or enabled states stay separate to preserve user choices.
enum AskKeywordAliases {
    static func consolidate(_ keywords: [AskKeyword]) -> [AskKeyword] {
        keywords.reduce(into: []) { result, keyword in
            if let index = result.firstIndex(where: {
                $0.pluginID == keyword.pluginID && $0.options == keyword.options && $0.enabled == keyword.enabled
            }) {
                for word in keyword.allKeywords where !result[index].contains(word) {
                    result[index].aliases.append(word)
                }
            } else {
                result.append(keyword)
            }
        }
    }

    static func englishName(for keyword: AskKeyword) -> String? {
        switch keyword.pluginID {
        case AskTranslatePlugin.id:
            return AskTranslatePlugin.opensWordBook(keyword.options) ? "dictionary" : "translate"
        case AskPromptPlugin.id:
            guard let preset = keyword.options[AskPromptPlugin.presetOption] else { return nil }
            return ["polish": "polish", "summarize": "summarize", "explain": "explain"][preset]
        case AskWebSearchPlugin.id:
            return keyword.options[AskWebSearchPlugin.engineOption]
        case AskFileSearchPlugin.id: return "filesearch"
        case AskBrowserSearchPlugin.tabsID: return "tabsearch"
        case AskBrowserSearchPlugin.bookmarksID: return "bookmarksearch"
        case AskOpenChatPlugin.id: return "openchat"
        case AskPrefixPlugin.id: return "keyworddirectory"
        case AskSettingsPlugin.id: return "settings"
        case AskHistoryPlugin.id: return "chathistory"
        case AskNotesPlugin.id: return "notebook"
        default: return AskSystemCommand(pluginID: keyword.pluginID)?.defaultKeyword
        }
    }

    static func addingEnglishNames(_ keywords: [AskKeyword], reserved: Set<String> = []) -> [AskKeyword] {
        var result = keywords
        var taken = Set(keywords.flatMap(\.allKeywords).map { $0.lowercased() }).union(reserved)
        for index in result.indices {
            guard let name = englishName(for: result[index]), !taken.contains(name.lowercased()) else { continue }
            result[index].aliases.append(name)
            taken.insert(name.lowercased())
        }
        return result
    }
}
