import Foundation

/// A word the user types at the start of the launcher to reach a plugin, with
/// options it presets: `fy` → translate, `fyja` → translate into Japanese.
struct AskKeyword: Codable, Equatable, Hashable, Identifiable, Sendable {
    var keyword: String
    var pluginID: String
    var options: [String: String] = [:]
    var enabled = true

    var id: String { keyword.lowercased() }
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
        for keyword in keywords.filter(\.enabled).sorted(by: { $0.keyword.count > $1.keyword.count }) {
            let word = keyword.keyword.lowercased()
            guard !word.isEmpty, lowered.hasPrefix(word) else { continue }
            let rest = text.dropFirst(word.count)
            guard let first = rest.first else { return .hint(keyword) }
            guard separators.contains(first) else { continue }
            let argument = rest.dropFirst().drop(while: { $0 == " " || $0 == "\u{3000}" })
            return .active(keyword, argument: String(argument))
        }
        return nil
    }

    enum Problem: Equatable {
        case empty, tooLong, whitespace, slash, duplicate
    }

    static let maximumLength = 12

    /// Why `keyword` cannot be saved beside `others`, or nil when it can. Two
    /// keywords where one starts the other are fine: the separator decides.
    static func problem(with keyword: String, among others: [AskKeyword]) -> Problem? {
        let word = keyword.trimmingCharacters(in: .whitespaces)
        if word.isEmpty { return .empty }
        if word.count > maximumLength { return .tooLong }
        if word.contains(where: { $0.isWhitespace || separators.contains($0) }) { return .whitespace }
        if word.hasPrefix("/") { return .slash }
        if others.contains(where: { $0.keyword.lowercased() == word.lowercased() }) { return .duplicate }
        return nil
    }
}
