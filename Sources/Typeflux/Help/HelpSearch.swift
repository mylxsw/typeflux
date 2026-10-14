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
                guard let assigned = shortcut.keys else { return false }
                if let keys {
                    return Set(keys).isSubset(of: Set(assigned.map { $0.lowercased() }))
                }
                return matches([shortcut.title, shortcut.detail, assigned.joined()])
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

    /// Spoken names of keys, longest first so "command" is not read as "cmd" and the rest.
    private static let keyNames: [(String, String)] = [
        ("command", "⌘"), ("cmd", "⌘"), ("option", "⌥"), ("opt", "⌥"), ("alt", "⌥"),
        ("control", "⌃"), ("ctrl", "⌃"), ("shift", "⇧"), ("return", "↩"), ("enter", "↩"),
        ("space", "space"), ("escape", "esc"), ("esc", "esc"), ("tab", "⇥"), ("fn", "fn")
    ]
    private static let symbols: Set<Character> = ["⌘", "⌥", "⌃", "⇧", "↩", "⇥"]
    private static let modifiers: Set<String> = ["⌘", "⌥", "⌃", "⇧", "fn"]
}
