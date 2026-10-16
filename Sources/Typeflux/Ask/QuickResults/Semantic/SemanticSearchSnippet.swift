import Foundation

enum SemanticSearchSnippet {
    /// Display text only: evidence offsets continue to identify the complete persisted chunk.
    static func make(_ passage: String, ranking: SemanticSearchRanking) -> String {
        guard passage.count > 180 else { return passage }
        let needles = ranking.identifiers + ranking.quoted + [ranking.text] + ranking.terms.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        let match = needles.lazy.filter { !$0.isEmpty }.compactMap {
            find($0, in: passage, identifier: ranking.identifiers.contains($0))
        }.first
        guard let match else { return String(passage.prefix(180)) }
        let start = passage.index(match.lowerBound, offsetBy: -40, limitedBy: passage.startIndex) ?? passage.startIndex
        let end = passage.index(start, offsetBy: 180, limitedBy: passage.endIndex) ?? passage.endIndex
        // Keep a verbatim substring so existing PDF selection/highlighting still finds it.
        return String(passage[start ..< end])
    }

    private static func find(_ needle: String, in text: String, identifier: Bool) -> Range<String.Index>? {
        var start = text.startIndex
        func identifierCharacter(_ value: Character?) -> Bool {
            guard let value else { return false }
            return SemanticSearchRanking.normalize(String(value))
                .range(of: "[\\p{Latin}\\p{N}_-]", options: .regularExpression) != nil
        }
        while start < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: start ..< text.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
            if !identifier || (!identifierCharacter(text[..<range.lowerBound].last)
                && !identifierCharacter(text[range.upperBound...].first)) {
                return range
            }
            start = range.upperBound
        }
        return nil
    }
}
