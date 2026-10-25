import Foundation

/// What a search on the guide found, grouped the way the results list shows them.
struct HelpSearchResults: Equatable {
    var keywords: [HelpKeyword] = []
    var shortcuts: [HelpShortcut] = []
    var commands: [HelpCommand] = []
    var questions: [HelpQuestion] = []

    var isEmpty: Bool { count == 0 }
    var count: Int { keywords.count + shortcuts.count + commands.count + questions.count }
}

/// Searches keywords, shortcuts, commands and questions at once. Keys may be typed the way
/// people say them, in any order: "cmd k" finds ⌘K and "cmd opt a" finds ⌥⌘A.
enum HelpSearch {
    static func search(_ query: String, in catalog: HelpCatalog) -> HelpSearchResults {
        let needle = folded(query)
        guard !needle.isEmpty else { return HelpSearchResults() }
        let matches: ([String]) -> Bool = { fields in fields.contains { folded($0).contains(needle) } }
        let keys = keyTokens(query)
        return HelpSearchResults(
            keywords: keys == nil
                ? catalog.keywords.filter { matches($0.keyword.allKeywords + [$0.title, $0.detail]) } : [],
            shortcuts: catalog.shortcuts.filter { shortcut in
                if let keys {
                    guard let assigned = shortcut.keys else { return false }
                    return Set(keys).isSubset(of: searchableKeys(assigned))
                }
                return matches([shortcut.section.title, shortcut.title, shortcut.detail, shortcut.keys?.joined() ?? ""])
            },
            commands: keys == nil ? catalog.commands.filter { matches([$0.name, $0.title]) } : [],
            questions: keys == nil ? catalog.questions.filter { matches([$0.question, $0.answer]) } : []
        )
    }

    /// Lowercased with runs of spaces made one, so "Google  搜索" finds "google 搜索". Spaces are
    /// kept: dropping them would let "fy" match "if you".
    static func folded(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The keys of a query that names a shortcut, like "cmd k", "⌘K" or "shift+enter", as the
    /// lowercased keycaps the guide draws. Nil for ordinary text: it needs a modifier and at
    /// most one plain key, so "tab" still finds the `tab` keyword and "alt text" stays text.
    static func keyTokens(_ query: String) -> [String]? {
        var rest = Substring(folded(query).filter { !$0.isWhitespace && $0 != "+" })
        var tokens: [String] = []
        var plainKeys = 0
        while let first = rest.first {
            if let (name, symbol) = keyNames.first(where: { rest.hasPrefix($0.0) }) {
                tokens.append(symbol)
                rest = rest.dropFirst(name.count)
            } else {
                tokens.append(String(first))
                if !symbols.contains(first) { plainKeys += 1 }
                rest = rest.dropFirst()
            }
        }
        guard plainKeys <= 1, tokens.contains(where: { modifiers.contains($0) }) else { return nil }
        return tokens
    }

    /// Expand displayed alternatives and number ranges for queries such as "cmd 3".
    private static func searchableKeys(_ assigned: [String]) -> Set<String> {
        var result = Set<String>()
        for key in assigned {
            let range = key.split(separator: "–")
            if range.count == 2, let lower = Int(range[0]), let upper = Int(range[1]),
               lower >= 0, upper <= 9, lower <= upper {
                result.formUnion((lower...upper).map(String.init))
            } else if key != "/" || assigned.last == "/" {
                if let tokens = keyTokens(key) { result.formUnion(tokens) }
                else { result.insert(key.lowercased()) }
            }
        }
        return result
    }

    /// Spoken names of keys, longest first so "command" is not read as "cmd" and the rest.
    private static let keyNames: [(String, String)] = [
        ("command", "⌘"), ("cmd", "⌘"), ("option", "⌥"), ("opt", "⌥"), ("alt", "⌥"),
        ("control", "⌃"), ("ctrl", "⌃"), ("shift", "⇧"), ("return", "↩"), ("enter", "↩"),
        ("space", "space"), ("escape", "esc"), ("esc", "esc"), ("tab", "⇥"), ("fn", "fn")
    ]
    private static let symbols: Set<Character> = ["⌘", "⌥", "⌃", "⇧", "↩", "⇥"]
    private static let modifiers: Set<String> = ["⌘", "⌥", "⌃", "⇧", "fn"]
}
